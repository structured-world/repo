#!/usr/bin/env bash
# Exercises scripts/update-repos.sh against EMPTY repository trees: no
# deb/dists, no deb/pool, no rpm/. That is the state after a key rotation
# clears the published packages, and it must still produce a complete,
# signed APT repository. Cases:
#   1. no incoming packages at all
#   2. default dists with a dist-agnostic and a dist-specific deb
#   3. custom DEB_DISTS: a dist on disk that is not served is removed, with
#      its dist-specific packages, and an incoming package for it is skipped
#   4. a traversal token in DEB_DISTS (must be rejected before any mkdir)
#   5. an RPM release directory: signed metadata and its dnf repository file
#   6. a publish with no incoming RPMs still writes it for existing directories
#   7. the DEB pool keeps the KEEP_VERSIONS newest versions per dist and arch
#   8. an RPM release directory keeps the KEEP_VERSIONS newest versions
#   9. an invalid KEEP_VERSIONS, MAX_AGE_DAYS or RPM_RELEASES is refused
#  10. a DEB version built more than MAX_AGE_DAYS ago is removed, the newest
#      version of its group stays however old
#  11. the same age limit for RPMs
#  12. a Fedora release that is not served: its directory and source packages
#      are removed and an incoming package for it is skipped
#  13. a rejected DEB_DISTS leaves an existing tree untouched
#  14. release lists split on any whitespace, tabs included
#  15. RPM retention orders by epoch first
#  16. one limit per dist over its dist-agnostic and dist-specific files
#  17. the limit counts versions: two builds of one version are one version
#  18. a release list with no names is refused, the tree untouched
#
# Requires: apt-ftparchive, dpkg-deb, gnupg, gzip, createrepo_c, rpm, rpmsign.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export GNUPGHOME="$WORK/gnupg"
mkdir -p "$GNUPGHOME"
chmod 700 "$GNUPGHOME"
gpg --batch --pinentry-mode loopback --passphrase '' \
  --quick-gen-key "repo test <test@example.invalid>" default default never >/dev/null 2>&1

fail() { echo "FAIL: $*" >&2; exit 1; }

# fresh_repo NAME: an empty repository tree holding only the script under test.
fresh_repo() {
  REPO="$WORK/$1"
  mkdir -p "$REPO/scripts"
  cp "$ROOT_DIR/scripts/update-repos.sh" "$ROOT_DIR/scripts/releases.env" "$REPO/scripts/"
  chmod +x "$REPO/scripts/update-repos.sh"
}

# mkdeb NAME VERSION ARCH [DIST [BUILT]]: a throwaway deb in the incoming
# directory; BUILT (seconds since the epoch) sets its build time.
mkdeb() {
  local name="$1" ver="$2" arch="$3" dist="${4:-}" built="${5:-$(date +%s)}"
  local d="$WORK/build/$name"
  rm -rf "$d"
  mkdir -p "$d/DEBIAN" "$d/usr/share/doc/$name" "$REPO/packages/deb"
  printf 'Package: %s\nVersion: %s\nArchitecture: %s\nMaintainer: t <t@example.invalid>\nDescription: test\n' \
    "$name" "$ver" "$arch" > "$d/DEBIAN/control"
  echo test > "$d/usr/share/doc/$name/README"
  SOURCE_DATE_EPOCH="$built" dpkg-deb -b "$d" \
    "$REPO/packages/deb/${name}_${ver}${dist:+_$dist}_${arch}.deb" >/dev/null
}

# primary_xml DIR: the primary metadata of the RPM repository in DIR, read
# through the file repomd.xml names and the decompressor its suffix calls for
# (createrepo_c's default compression differs between versions).
primary_xml() {
  local href
  href=$(grep -o 'href="repodata/[^"]*primary\.xml[^"]*"' "$1/repodata/repomd.xml" | head -n1)
  href="${href#href=\"}"
  href="${href%\"}"
  case "$href" in
    *.gz) zcat "$1/$href" ;;
    *.zst) zstd -dcq "$1/$href" ;;
    *.xz) xzcat "$1/$href" ;;
    *.bz2) bzcat "$1/$href" ;;
    *) cat "$1/$href" ;;
  esac
}

# mkrpm VERSION RELEASE [EPOCH]: a throwaway noarch RPM in the incoming
# directory, from the probe spec.
mkrpm() {
  local ver="$1" rel="$2" epoch="${3:-}" spec
  spec="$HOME/rpmbuild/SPECS/probe-$ver-$rel-${epoch:-0}.spec"
  sed -e "s/^Version: 1.0$/Version: $ver/" -e "s/^Release: 1.fc44$/Release: $rel/" \
    "$HOME/rpmbuild/SPECS/probe.spec" > "$spec"
  if [ -n "$epoch" ]; then
    sed -i "s/^Name: probe$/Name: probe\nEpoch: $epoch/" "$spec"
  fi
  rpmbuild -bb --define "_topdir $HOME/rpmbuild" "$spec" >/dev/null 2>&1 \
    || fail "$CASE: could not build probe $ver-$rel"
  mkdir -p "$REPO/packages/rpm"
  cp "$HOME/rpmbuild/RPMS/noarch/probe-$ver-$rel.noarch.rpm" "$REPO/packages/rpm/"
}

# assert_dist_indexed DIST: signed Release/InRelease and a Packages.gz per arch.
assert_dist_indexed() {
  local dist="$1" arch
  for arch in amd64 arm64; do
    [ -f "$REPO/deb/dists/$dist/main/binary-$arch/Packages" ] \
      || fail "$CASE: missing Packages for $dist/$arch"
    [ -s "$REPO/deb/dists/$dist/main/binary-$arch/Packages.gz" ] \
      || fail "$CASE: missing Packages.gz for $dist/$arch"
  done
  gpg --verify "$REPO/deb/dists/$dist/InRelease" >/dev/null 2>&1 \
    || fail "$CASE: InRelease signature invalid for $dist"
  gpg --verify "$REPO/deb/dists/$dist/Release.gpg" "$REPO/deb/dists/$dist/Release" >/dev/null 2>&1 \
    || fail "$CASE: Release.gpg signature invalid for $dist"
}

# --- case 1: nothing incoming, no pool ---------------------------------------
CASE="empty-input"
fresh_repo "$CASE"
(cd "$REPO" && scripts/update-repos.sh)
for dist in bookworm trixie noble resolute; do
  assert_dist_indexed "$dist"
  [ ! -s "$REPO/deb/dists/$dist/main/binary-amd64/Packages" ] \
    || fail "$CASE: Packages for $dist is not empty"
done

# --- case 2: default dists, agnostic + dist-specific debs -------------------
CASE="default-dists"
fresh_repo "$CASE"
mkdeb agnostic 1.0 amd64
mkdeb noblonly 1.0 amd64 noble
(cd "$REPO" && scripts/update-repos.sh)
for dist in bookworm trixie noble resolute; do
  assert_dist_indexed "$dist"
  grep -q '^Package: agnostic$' "$REPO/deb/dists/$dist/main/binary-amd64/Packages" \
    || fail "$CASE: dist-agnostic package missing from $dist"
done
grep -q '^Package: noblonly$' "$REPO/deb/dists/noble/main/binary-amd64/Packages" \
  || fail "$CASE: noble-specific package missing from noble"
if grep -q '^Package: noblonly$' "$REPO/deb/dists/bookworm/main/binary-amd64/Packages"; then
  fail "$CASE: noble-specific package leaked into bookworm"
fi
grep -q '^Filename: pool/main/a/agnostic/agnostic_1.0_amd64.deb$' \
  "$REPO/deb/dists/trixie/main/binary-amd64/Packages" \
  || fail "$CASE: Filename is not pool-relative"

# --- case 3: custom DEB_DISTS, a dist on disk that is not served goes -------
CASE="custom-dists"
fresh_repo "$CASE"
mkdir -p "$REPO/deb/dists/jammy/main/binary-amd64" "$REPO/deb/pool/main/j/jamonly"
mkdeb jamonly 1.0 amd64 jammy
mv "$REPO/packages/deb/jamonly_1.0_jammy_amd64.deb" "$REPO/deb/pool/main/j/jamonly/"
mkdeb agnostic 1.0 amd64
mkdeb jamonly 1.1 amd64 jammy
(cd "$REPO" && DEB_DISTS="trixie" scripts/update-repos.sh)
assert_dist_indexed trixie
[ ! -e "$REPO/deb/dists/bookworm" ] || fail "$CASE: default dist created despite custom DEB_DISTS"
[ ! -e "$REPO/deb/dists/jammy" ] || fail "$CASE: a dist that is not served kept"
[ ! -e "$REPO/deb/pool/main/j/jamonly/jamonly_1.0_jammy_amd64.deb" ] \
  || fail "$CASE: a package for a dist that is not served kept in the pool"
[ ! -e "$REPO/deb/pool/main/j/jamonly/jamonly_1.1_jammy_amd64.deb" ] \
  || fail "$CASE: an incoming package for a dist that is not served published"
grep -q '^Package: agnostic$' "$REPO/deb/dists/trixie/main/binary-amd64/Packages" \
  || fail "$CASE: package missing from configured dist"

# --- case 4: traversal token rejected before any directory is made ---------
CASE="traversal-dist"
fresh_repo "$CASE"
if (cd "$REPO" && DEB_DISTS="../staging" scripts/update-repos.sh >/dev/null 2>&1); then
  fail "$CASE: script accepted a traversal dist name"
fi
[ ! -e "$REPO/deb/staging" ] || fail "$CASE: traversal dist created deb/staging"
[ ! -e "$REPO/deb/dists" ] || fail "$CASE: directories were created before validation"

# --- case 5: an RPM release directory gets its signed metadata and dnf file -
CASE="rpm-repo-file"
fresh_repo "$CASE"
fpr="$(gpg --batch --with-colons --list-secret-keys | awk -F: '/^fpr:/ {print $10; exit}')"
export HOME="$WORK/home-$CASE"
mkdir -p "$HOME/rpmbuild/SPECS" "$REPO/packages/rpm"
# The same signing macros the publish workflow writes, against the test key.
printf '%%_signature gpg\n%%_gpg_name %s\n%%_gpg_path %s\n%%__gpg /usr/bin/gpg\n' \
  "$fpr" "$GNUPGHOME" > "$HOME/.rpmmacros"
# A private RPM database, so the test key never enters the machine's trust
# store; the script under test reads the same macros for its checksig.
printf '%%_dbpath %s\n' "$WORK/rpmdb" >> "$HOME/.rpmmacros"
mkdir -p "$WORK/rpmdb"
rpm --initdb || fail "$CASE: could not create the private RPM database"
cat > "$HOME/rpmbuild/SPECS/probe.spec" << 'EOF_SPEC'
Name: probe
Version: 1.0
Release: 1.fc44
Summary: test
License: MIT
BuildArch: noarch
%description
test
%files
EOF_SPEC
rpmbuild -bb --define "_topdir $HOME/rpmbuild" "$HOME/rpmbuild/SPECS/probe.spec" >/dev/null 2>&1 \
  || fail "$CASE: could not build the probe RPM"
cp "$HOME"/rpmbuild/RPMS/noarch/probe-1.0-1.fc44.noarch.rpm "$REPO/packages/rpm/"
gpg --batch --armor --export "$fpr" > "$WORK/probe-key.asc"
rpm --import "$WORK/probe-key.asc" || fail "$CASE: could not import the probe key"
(cd "$REPO" && scripts/update-repos.sh) || fail "$CASE: publish failed"
repo_file="$REPO/rpm/fc44/sw.repo"
[ -f "$repo_file" ] || fail "$CASE: no sw.repo for fc44"
# dnf's own $releasever, so a host upgraded to the next Fedora release
# follows that release's directory instead of the one it was set up on.
grep -qx 'baseurl=https://repo.sw.foundation/rpm/fc$releasever/' "$repo_file" \
  || fail "$CASE: sw.repo does not follow the host's Fedora release"
grep -qx 'gpgcheck=1' "$repo_file" || fail "$CASE: package signatures not required"
grep -qx 'repo_gpgcheck=1' "$repo_file" || fail "$CASE: metadata signature not required"
grep -qx 'gpgkey=https://repo.sw.foundation/keys/sw.asc' "$repo_file" \
  || fail "$CASE: sw.repo does not name the published key"
gpg --verify "$REPO/rpm/fc44/repodata/repomd.xml.asc" "$REPO/rpm/fc44/repodata/repomd.xml" >/dev/null 2>&1 \
  || fail "$CASE: repomd.xml signature invalid"

# --- case 6: a publish without RPMs still serves existing release dirs -----
# A DEB-only publish leaves packages/rpm empty; the release directories
# already on disk must still get their dnf repository file.
CASE="rpm-repo-file-no-incoming"
previous="$REPO"
fresh_repo "$CASE"
mkdir -p "$REPO/rpm/fc44" "$REPO/packages/rpm"
cp "$previous"/rpm/fc44/*.rpm "$REPO/rpm/fc44/"
(cd "$REPO" && scripts/update-repos.sh) || fail "$CASE: publish failed"
[ -f "$REPO/rpm/fc44/sw.repo" ] || fail "$CASE: no sw.repo for the existing fc44 directory"
gpg --verify "$REPO/rpm/fc44/repodata/repomd.xml.asc" "$REPO/rpm/fc44/repodata/repomd.xml" >/dev/null 2>&1 \
  || fail "$CASE: repomd.xml signature invalid"

# --- case 7: the pool keeps the KEEP_VERSIONS newest versions per group ----
# Versions ordered as dpkg orders them (1.10 after 1.9, which a string sort
# gets wrong); each dist and architecture is its own group, and the indexes
# list only what the pool keeps.
CASE="deb-retention"
fresh_repo "$CASE"
for ver in 1.6 1.7 1.8 1.9 1.10 1.11 1.12; do
  mkdeb agnostic "$ver" amd64
done
mkdeb agnostic 1.0 arm64
mkdeb noblonly 1.0 amd64 noble
mkdeb noblonly 1.1 amd64 noble
(cd "$REPO" && KEEP_VERSIONS=5 scripts/update-repos.sh) || fail "$CASE: publish failed"
pool="$REPO/deb/pool/main/a/agnostic"
for ver in 1.8 1.9 1.10 1.11 1.12; do
  [ -e "$pool/agnostic_${ver}_amd64.deb" ] || fail "$CASE: newest version $ver pruned"
done
for ver in 1.6 1.7; do
  [ ! -e "$pool/agnostic_${ver}_amd64.deb" ] || fail "$CASE: old version $ver kept"
done
[ -e "$pool/agnostic_1.0_arm64.deb" ] || fail "$CASE: another architecture's version pruned"
for ver in 1.0 1.1; do
  [ -e "$REPO/deb/pool/main/n/noblonly/noblonly_${ver}_noble_amd64.deb" ] \
    || fail "$CASE: a dist-specific version $ver pruned"
done
packages="$REPO/deb/dists/trixie/main/binary-amd64/Packages"
[ "$(grep -c '^Package: agnostic$' "$packages")" -eq 5 ] \
  || fail "$CASE: the index does not list exactly the kept versions"
if grep -q '^Version: 1.7$' "$packages"; then
  fail "$CASE: the index lists a pruned version"
fi

# --- case 8: an RPM release directory keeps the newest versions too --------
CASE="rpm-retention"
fresh_repo "$CASE"
mkdir -p "$REPO/packages/rpm"
for ver in 1.8 1.9 1.10 1.11 1.12 1.13; do
  sed "s/^Version: 1.0$/Version: $ver/" "$HOME/rpmbuild/SPECS/probe.spec" \
    > "$HOME/rpmbuild/SPECS/probe-$ver.spec"
  rpmbuild -bb --define "_topdir $HOME/rpmbuild" "$HOME/rpmbuild/SPECS/probe-$ver.spec" >/dev/null 2>&1 \
    || fail "$CASE: could not build probe $ver"
  cp "$HOME/rpmbuild/RPMS/noarch/probe-$ver-1.fc44.noarch.rpm" "$REPO/packages/rpm/"
done
(cd "$REPO" && KEEP_VERSIONS=5 scripts/update-repos.sh) || fail "$CASE: publish failed"
[ ! -e "$REPO/rpm/fc44/probe-1.8-1.fc44.noarch.rpm" ] || fail "$CASE: the oldest version kept"
for ver in 1.9 1.10 1.11 1.12 1.13; do
  [ -e "$REPO/rpm/fc44/probe-$ver-1.fc44.noarch.rpm" ] || fail "$CASE: newest version $ver pruned"
done
[ "$(primary_xml "$REPO/rpm/fc44" | grep -c '<name>probe</name>')" -eq 5 ] \
  || fail "$CASE: the metadata does not list exactly the kept versions"

# --- case 9: invalid limits and release lists are refused ------------------
CASE="settings-invalid"
fresh_repo "$CASE"
for setting in KEEP_VERSIONS=0 MAX_AGE_DAYS=0 MAX_AGE_DAYS=a RPM_RELEASES=4x; do
  if (cd "$REPO" && env "$setting" scripts/update-repos.sh >/dev/null 2>&1); then
    fail "$CASE: $setting accepted"
  fi
done
[ ! -e "$REPO/deb" ] || fail "$CASE: the tree was touched before the settings were checked"

# --- case 10: DEB versions past the age limit go, the newest stays ---------
CASE="deb-age"
fresh_repo "$CASE"
now=$(date +%s)
old=$((now - 400 * 86400))
mkdeb fresh 1.0 amd64 "" "$old"
mkdeb fresh 1.1 amd64 "" "$old"
mkdeb fresh 1.2 amd64 "" "$now"
mkdeb stale 2.0 amd64 "" "$old"
mkdeb stale 2.1 amd64 "" "$old"
(cd "$REPO" && MAX_AGE_DAYS=365 scripts/update-repos.sh) || fail "$CASE: publish failed"
for f in fresh/fresh_1.0_amd64 fresh/fresh_1.1_amd64 stale/stale_2.0_amd64; do
  [ ! -e "$REPO/deb/pool/main/${f:0:1}/$f.deb" ] || fail "$CASE: $f kept past the age limit"
done
[ -e "$REPO/deb/pool/main/f/fresh/fresh_1.2_amd64.deb" ] || fail "$CASE: a recent version pruned"
[ -e "$REPO/deb/pool/main/s/stale/stale_2.1_amd64.deb" ] \
  || fail "$CASE: the newest version of a group pruned for its age"

# --- case 11: RPM versions past the age limit go, the newest stays ---------
CASE="rpm-age"
fresh_repo "$CASE"
mkdir -p "$REPO/packages/rpm"
for ver in 3.0 3.1; do
  sed "s/^Version: 1.0$/Version: $ver/" "$HOME/rpmbuild/SPECS/probe.spec" \
    > "$HOME/rpmbuild/SPECS/probe-$ver.spec"
  # rpmbuild stamps SOURCE_DATE_EPOCH as the build time when told to.
  SOURCE_DATE_EPOCH="$old" rpmbuild -bb --define "_topdir $HOME/rpmbuild" \
    --define "use_source_date_epoch_as_buildtime 1" \
    "$HOME/rpmbuild/SPECS/probe-$ver.spec" >/dev/null 2>&1 \
    || fail "$CASE: could not build probe $ver"
  cp "$HOME/rpmbuild/RPMS/noarch/probe-$ver-1.fc44.noarch.rpm" "$REPO/packages/rpm/"
done
(cd "$REPO" && MAX_AGE_DAYS=365 scripts/update-repos.sh) || fail "$CASE: publish failed"
[ ! -e "$REPO/rpm/fc44/probe-3.0-1.fc44.noarch.rpm" ] || fail "$CASE: an old version kept"
[ -e "$REPO/rpm/fc44/probe-3.1-1.fc44.noarch.rpm" ] \
  || fail "$CASE: the newest version pruned for its age"

# --- case 12: a Fedora release that is not served --------------------------
CASE="rpm-release-not-served"
fresh_repo "$CASE"
mkdir -p "$REPO/rpm/fc41/repodata" "$REPO/packages/rpm"
touch "$REPO/rpm/fc41/sw.repo"
sed -e "s/^Release: 1.fc44$/Release: 1.fc43/" "$HOME/rpmbuild/SPECS/probe.spec" \
  > "$HOME/rpmbuild/SPECS/probe-fc43.spec"
rpmbuild -bb --define "_topdir $HOME/rpmbuild" "$HOME/rpmbuild/SPECS/probe-fc43.spec" >/dev/null 2>&1 \
  || fail "$CASE: could not build the fc43 probe"
cp "$HOME/rpmbuild/RPMS/noarch/probe-1.0-1.fc43.noarch.rpm" "$REPO/packages/rpm/"
(cd "$REPO" && scripts/update-repos.sh) || fail "$CASE: publish failed"
[ ! -e "$REPO/rpm/fc41" ] || fail "$CASE: a release directory that is not served kept"
[ ! -e "$REPO/rpm/fc43" ] || fail "$CASE: a package for a release that is not served published"

# --- case 13: a rejected DEB_DISTS leaves the tree untouched ---------------
# The settings are checked before anything is copied, pruned or removed: a
# bad value must not make every dist-specific package look retired.
CASE="deb-dists-invalid-existing-tree"
fresh_repo "$CASE"
mkdir -p "$REPO/deb/pool/main/n/noblonly"
mkdeb noblonly 1.0 amd64 noble
mv "$REPO/packages/deb/noblonly_1.0_noble_amd64.deb" "$REPO/deb/pool/main/n/noblonly/"
if (cd "$REPO" && DEB_DISTS="../staging" scripts/update-repos.sh >/dev/null 2>&1); then
  fail "$CASE: script accepted a traversal dist name"
fi
[ -e "$REPO/deb/pool/main/n/noblonly/noblonly_1.0_noble_amd64.deb" ] \
  || fail "$CASE: a rejected setting deleted a served package"

# --- case 14: release lists split on any whitespace -------------------------
CASE="release-lists-whitespace"
fresh_repo "$CASE"
mkdir -p "$REPO/rpm/fc44"
cp "$previous"/rpm/fc44/*.rpm "$REPO/rpm/fc44/"
mkdeb noblonly 1.0 amd64 noble
(cd "$REPO" && RPM_RELEASES=$'44\t45' DEB_DISTS=$'trixie\tnoble' scripts/update-repos.sh) \
  || fail "$CASE: publish failed"
[ -n "$(find "$REPO/rpm/fc44" -name '*.rpm' -print -quit)" ] \
  || fail "$CASE: a release listed after a tab was removed"
[ -e "$REPO/deb/pool/main/n/noblonly/noblonly_1.0_noble_amd64.deb" ] \
  || fail "$CASE: a package for a dist listed after a tab was skipped"
assert_dist_indexed noble

# --- case 15: RPM retention follows the epoch -------------------------------
# 1:1.0 is newer than 0:9.0; with one version kept, the epoch bump stays.
CASE="rpm-epoch"
fresh_repo "$CASE"
mkrpm 9.0 1.fc44
mkrpm 1.0 2.fc44 1
(cd "$REPO" && KEEP_VERSIONS=1 scripts/update-repos.sh) || fail "$CASE: publish failed"
[ -e "$REPO/rpm/fc44/probe-1.0-2.fc44.noarch.rpm" ] || fail "$CASE: the epoch bump pruned"
[ ! -e "$REPO/rpm/fc44/probe-9.0-1.fc44.noarch.rpm" ] || fail "$CASE: the older epoch kept"

# --- case 16: one limit per dist over dist-agnostic and dist-specific files -
# A package moving from one dist-agnostic build to builds per dist: what a
# dist's index lists (its own files and the dist-agnostic ones) holds at most
# KEEP_VERSIONS versions, and a dist-agnostic file no served dist still
# lists is removed.
CASE="deb-mixed-retention"
fresh_repo "$CASE"
for ver in 1.0 1.1 1.2; do
  mkdeb mixed "$ver" amd64
done
for ver in 2.0 2.1; do
  mkdeb mixed "$ver" amd64 noble
done
(cd "$REPO" && DEB_DISTS="noble trixie" KEEP_VERSIONS=2 scripts/update-repos.sh) \
  || fail "$CASE: publish failed"
noble="$REPO/deb/dists/noble/main/binary-amd64/Packages"
trixie="$REPO/deb/dists/trixie/main/binary-amd64/Packages"
[ "$(grep -c '^Package: mixed$' "$noble")" -eq 2 ] || fail "$CASE: noble lists more than the limit"
grep -q '^Version: 2.1$' "$noble" || fail "$CASE: noble lacks its newest version"
grep -q '^Version: 2.0$' "$noble" || fail "$CASE: noble lacks its second version"
[ "$(grep -c '^Package: mixed$' "$trixie")" -eq 2 ] || fail "$CASE: trixie does not keep two versions"
grep -q '^Version: 1.2$' "$trixie" || fail "$CASE: trixie lacks the newest dist-agnostic version"
pool="$REPO/deb/pool/main/m/mixed"
[ ! -e "$pool/mixed_1.0_amd64.deb" ] || fail "$CASE: a version no dist lists kept"
(cd "$REPO" && DEB_DISTS="noble" KEEP_VERSIONS=2 scripts/update-repos.sh) \
  || fail "$CASE: second publish failed"
for ver in 1.1 1.2; do
  [ ! -e "$pool/mixed_${ver}_amd64.deb" ] || fail "$CASE: dist-agnostic $ver kept with no dist listing it"
done

# --- case 17: the limit counts versions, not files --------------------------
# During the move to builds per dist, one version can sit in a dist's index
# twice (its dist-agnostic and its dist-specific build); that is still one
# version, and the previous one stays.
CASE="deb-same-version-two-builds"
fresh_repo "$CASE"
mkdeb dual 1.9 amd64
mkdeb dual 2.0 amd64
mkdeb dual 2.0 amd64 noble
(cd "$REPO" && DEB_DISTS="noble" KEEP_VERSIONS=2 scripts/update-repos.sh) \
  || fail "$CASE: publish failed"
pool="$REPO/deb/pool/main/d/dual"
[ -e "$pool/dual_1.9_amd64.deb" ] || fail "$CASE: a second build of 2.0 crowded out 1.9"
[ -e "$pool/dual_2.0_amd64.deb" ] || fail "$CASE: the dist-agnostic 2.0 pruned"
[ -e "$pool/dual_2.0_noble_amd64.deb" ] || fail "$CASE: the noble 2.0 pruned"
grep -q '^Version: 1.9$' "$REPO/deb/dists/noble/main/binary-amd64/Packages" \
  || fail "$CASE: noble does not list 1.9"

# --- case 18: a release list with no names is refused -----------------------
# Whitespace alone yields no dist or release: refused before anything is
# copied, pruned or removed, instead of every served package looking retired.
CASE="release-lists-blank"
fresh_repo "$CASE"
mkdir -p "$REPO/deb/pool/main/a/agnostic"
mkdeb agnostic 1.0 amd64
mv "$REPO/packages/deb/agnostic_1.0_amd64.deb" "$REPO/deb/pool/main/a/agnostic/"
mkdir -p "$REPO/rpm/fc44"
cp "$previous"/rpm/fc44/*.rpm "$REPO/rpm/fc44/"
for setting in DEB_DISTS=$' \t\n' RPM_RELEASES=$' \t\n'; do
  if (cd "$REPO" && env "$setting" scripts/update-repos.sh >/dev/null 2>&1); then
    fail "$CASE: a blank ${setting%%=*} accepted"
  fi
done
[ -e "$REPO/deb/pool/main/a/agnostic/agnostic_1.0_amd64.deb" ] \
  || fail "$CASE: a blank list deleted a served package"
[ -n "$(find "$REPO/rpm/fc44" -name '*.rpm' -print -quit)" ] \
  || fail "$CASE: a blank list removed a served release"

echo "update-repos.sh: publish OK (18 cases)"
