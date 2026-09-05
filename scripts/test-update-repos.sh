#!/usr/bin/env bash
# Exercises scripts/update-repos.sh against EMPTY repository trees: no
# deb/dists, no deb/pool, no rpm/. That is the state after a key rotation
# clears the published packages, and it must still produce a complete,
# signed APT repository. Cases:
#   1. no incoming packages at all
#   2. default dists with a dist-agnostic and a dist-specific deb
#   3. custom DEB_DISTS plus a dist already on disk (must be retained)
#   4. a traversal token in DEB_DISTS (must be rejected before any mkdir)
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
  cp "$ROOT_DIR/scripts/update-repos.sh" "$REPO/scripts/update-repos.sh"
  chmod +x "$REPO/scripts/update-repos.sh"
}

# mkdeb NAME VERSION ARCH [DIST]: a throwaway deb in the incoming directory.
mkdeb() {
  local name="$1" ver="$2" arch="$3" dist="${4:-}"
  local d="$WORK/build/$name"
  rm -rf "$d"
  mkdir -p "$d/DEBIAN" "$d/usr/share/doc/$name" "$REPO/packages/deb"
  printf 'Package: %s\nVersion: %s\nArchitecture: %s\nMaintainer: t <t@example.invalid>\nDescription: test\n' \
    "$name" "$ver" "$arch" > "$d/DEBIAN/control"
  echo test > "$d/usr/share/doc/$name/README"
  dpkg-deb -b "$d" "$REPO/packages/deb/${name}_${ver}${dist:+_$dist}_${arch}.deb" >/dev/null
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
for dist in bookworm jammy noble; do
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
for dist in bookworm jammy noble; do
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
  "$REPO/deb/dists/jammy/main/binary-amd64/Packages" \
  || fail "$CASE: Filename is not pool-relative"

# --- case 3: custom DEB_DISTS, pre-existing dist retained -------------------
CASE="custom-dists"
fresh_repo "$CASE"
mkdir -p "$REPO/deb/dists/noble"
mkdeb agnostic 1.0 amd64
(cd "$REPO" && DEB_DISTS="trixie" scripts/update-repos.sh)
assert_dist_indexed trixie
assert_dist_indexed noble
[ ! -e "$REPO/deb/dists/bookworm" ] || fail "$CASE: default dist created despite custom DEB_DISTS"
grep -q '^Package: agnostic$' "$REPO/deb/dists/trixie/main/binary-amd64/Packages" \
  || fail "$CASE: package missing from configured dist"
grep -q '^Package: agnostic$' "$REPO/deb/dists/noble/main/binary-amd64/Packages" \
  || fail "$CASE: package missing from retained dist"

# --- case 4: traversal token rejected before any directory is made ---------
CASE="traversal-dist"
fresh_repo "$CASE"
if (cd "$REPO" && DEB_DISTS="../staging" scripts/update-repos.sh >/dev/null 2>&1); then
  fail "$CASE: script accepted a traversal dist name"
fi
[ ! -e "$REPO/deb/staging" ] || fail "$CASE: traversal dist created deb/staging"
[ ! -e "$REPO/deb/dists" ] || fail "$CASE: directories were created before validation"

echo "update-repos.sh: empty-tree publish OK (4 cases)"
