#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

umask 022

DEB_SRC_DIR="${DEB_SRC_DIR:-packages/deb}"
RPM_SRC_DIR="${RPM_SRC_DIR:-packages/rpm}"
SRPM_SRC_DIR="${SRPM_SRC_DIR:-packages/srpm}"
# Binary architectures indexed for every DEB dist.
DEB_ARCHS="${DEB_ARCHS:-amd64 arm64}"
# shellcheck source=releases.env
. "$ROOT_DIR/scripts/releases.env"
# Dists the repository serves: their directories are created on demand, so a
# fresh tree (or one cleared for a key rotation) is indexed without any dist
# directory pre-existing. A dist directory not listed here is removed, with
# the dist-specific packages built for it.
DEB_DISTS="${DEB_DISTS:-$SERVED_DEB_DISTS}"
# Fedora releases the repository serves. A release directory not listed here
# is removed; an incoming package built for another release is skipped.
RPM_RELEASES="${RPM_RELEASES:-$SERVED_RPM_RELEASES}"
# Where the repository is served; the dnf repository files point there.
REPO_BASE_URL="${REPO_BASE_URL:-https://repo.sw.foundation}"
# How many versions of a package each dist and architecture (DEB), Fedora
# release and architecture (RPM) or the source directory (SRPM) keeps: the
# newest by the package manager's own ordering. Older ones are removed from
# the served tree before it is indexed.
KEEP_VERSIONS="${KEEP_VERSIONS:-5}"
# Of those, a version built more than this many days ago is removed too; the
# newest version of a group always stays, however old.
MAX_AGE_DAYS="${MAX_AGE_DAYS:-365}"
for setting in KEEP_VERSIONS MAX_AGE_DAYS; do
  if ! [[ "${!setting}" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: $setting must be a positive integer, got '${!setting}'" >&2
    exit 1
  fi
done
# Each list is split once, on any whitespace, and every check below (validity,
# membership, iteration) uses these same tokens.
read -r -d '' -a SERVED_RELEASES <<< "$RPM_RELEASES" || true
read -r -d '' -a SERVED_DISTS <<< "$DEB_DISTS" || true
# A list with no names would make every served release look retired.
if [ "${#SERVED_RELEASES[@]}" -eq 0 ] || [ "${#SERVED_DISTS[@]}" -eq 0 ]; then
  echo "Error: RPM_RELEASES and DEB_DISTS must each name at least one release" >&2
  exit 1
fi
for release in "${SERVED_RELEASES[@]}"; do
  if ! [[ "$release" =~ ^[0-9]+$ ]]; then
    echo "Error: invalid Fedora release '$release' in RPM_RELEASES" >&2
    exit 1
  fi
done
# Checked before anything is copied, pruned or removed: a rejected value must
# leave the tree as it was, not make every dist-specific package look retired.
# The name becomes a path component, so separators and traversal are refused.
for dist in "${SERVED_DISTS[@]}"; do
  if ! [[ "$dist" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "Error: invalid dist name '$dist' in DEB_DISTS" >&2
    exit 1
  fi
done
# Build times before this one are past MAX_AGE_DAYS.
AGE_CUTOFF=$(( $(date +%s) - MAX_AGE_DAYS * 86400 ))

# rpm_release_served N: whether Fedora release N is in RPM_RELEASES.
rpm_release_served() {
  local release
  for release in "${SERVED_RELEASES[@]}"; do
    [ "$release" = "$1" ] && return 0
  done
  return 1
}

# deb_dist_served DIST: whether DIST is in DEB_DISTS.
deb_dist_served() {
  local dist
  for dist in "${SERVED_DISTS[@]}"; do
    [ "$dist" = "$1" ] && return 0
  done
  return 1
}

# deb_file_dist FILE: the dist token of a dist-specific file name
# (name_version_dist_arch.deb), empty for a dist-agnostic one
# (name_version_arch.deb). Neither a name nor a version holds '_'.
deb_file_dist() {
  local -a fields
  IFS=_ read -r -a fields <<< "$(basename "$1" .deb)"
  if [ "${#fields[@]}" -eq 4 ]; then
    printf '%s' "${fields[2]}"
  fi
}

# select_kept KIND ENTRY...: of the files of one package group, print the
# paths kept: those of the KEEP_VERSIONS newest versions, less any built
# before AGE_CUTOFF outside the newest version. The limit counts versions,
# not files: a version's dist-agnostic and dist-specific builds share one
# slot. KIND is deb or rpm and picks the comparison; each entry is
# "<version>\t<build time>\t<path>".
select_kept() {
  local kind="$1"
  shift
  local -a entries=("$@")
  # Selection by the package manager's comparison: a group holds a few
  # dozen versions at most.
  local -a ordered=()
  while [ "${#entries[@]}" -gt 0 ]; do
    local newest=0 i
    for ((i = 1; i < ${#entries[@]}; i++)); do
      if version_newer "$kind" "${entries[$i]%%$'\t'*}" "${entries[$newest]%%$'\t'*}"; then
        newest=$i
      fi
    done
    ordered+=("${entries[$newest]}")
    entries=("${entries[@]:0:$newest}" "${entries[@]:$((newest + 1))}")
  done
  # Equal versions sit next to each other in that order; rank counts the
  # distinct versions seen so far, 0 for the newest.
  local entry built version previous="" rank=-1
  for ((i = 0; i < ${#ordered[@]}; i++)); do
    version="${ordered[$i]%%$'\t'*}"
    if [ "$rank" -lt 0 ] || version_newer "$kind" "$previous" "$version"; then
      rank=$((rank + 1))
      previous="$version"
    fi
    [ "$rank" -lt "$KEEP_VERSIONS" ] || break
    entry="${ordered[$i]#*$'\t'}"
    built="${entry%%$'\t'*}"
    if [ "$rank" -eq 0 ] || [ "$built" -ge "$AGE_CUTOFF" ]; then
      printf '%s\n' "${entry#*$'\t'}"
    fi
  done
}

# prune_group KIND ENTRY...: remove the files of one package group that
# select_kept does not keep.
prune_group() {
  local kind="$1"
  shift
  local -A kept=()
  local path entry
  while IFS= read -r path; do
    kept[$path]=1
  done < <(select_kept "$kind" "$@")
  for entry in "$@"; do
    path="${entry##*$'\t'}"
    if [ -z "${kept[$path]:-}" ]; then
      rm -f -- "$path"
      echo "Pruned $path (past the $KEEP_VERSIONS newest versions or $MAX_AGE_DAYS days)"
    fi
  done
}

# Per served dist, the dist-agnostic file names its index leaves out: a file
# another dist still keeps but this one no longer counts among its newest.
declare -A DEB_INDEX_EXCLUDED=()

# version_newer KIND A B: whether version A sorts after B. An RPM version is
# EPOCH:VERSION-RELEASE, compared as rpm compares them (epoch first).
version_newer() {
  local kind="$1" a="$2" b="$3"
  if [ "$kind" = deb ]; then
    dpkg --compare-versions "$a" gt "$b"
  else
    [ "$(rpm --eval "%{lua: print(rpm.ver('$a') > rpm.ver('$b'))}")" = true ]
  fi
}

# rpm_evr_valid EVR: whether EVR has the shape and characters rpm allows in a
# version, so it can stand inside the Lua string literal above. The values
# come from package headers that another repository's build produced, while
# this script holds the signing key; a header is data, never code.
rpm_evr_valid() {
  [[ "$1" =~ ^[0-9]+:[A-Za-z0-9._+~^]+-[A-Za-z0-9._+~^]+$ ]]
}

# prune_deb_pool: a dist-specific package built for a dist the repository no
# longer serves is removed. Every other package is limited per served dist
# and architecture over what that dist's index lists: its own dist-specific
# files and the dist-agnostic ones, as select_kept chooses. A dist-agnostic
# file one dist drops while another keeps it is left out of the first one's
# index (DEB_INDEX_EXCLUDED); a file no served dist keeps is removed.
prune_deb_pool() {
  [ -d deb/pool ] || return 0
  local -A groups=()
  local deb name version arch dist built key
  while IFS= read -r -d '' deb; do
    dist="$(deb_file_dist "$deb")"
    if [ -n "$dist" ] && ! deb_dist_served "$dist"; then
      rm -f -- "$deb"
      echo "Removed $deb ($dist is not served)"
      continue
    fi
    name=$(dpkg-deb -f "$deb" Package) || continue
    version=$(dpkg-deb -f "$deb" Version) || continue
    arch=$(dpkg-deb -f "$deb" Architecture) || continue
    # The build time: dpkg-deb stamps it on the archive's members, and the
    # first member's ar header holds it as decimal seconds at bytes 24-35.
    built=$(head -c 36 "$deb" | tail -c 12 | tr -d ' ')
    [[ "$built" =~ ^[0-9]+$ ]] || continue
    key="$name|$arch"
    groups[$key]+="${dist}"$'\t'"${version}"$'\t'"${built}"$'\t'"${deb}"$'\n'
  done < <(find deb/pool -type f -name '*.deb' -print0)
  local -A kept=()
  local -a members subset
  local member entry_dist path served
  for key in "${!groups[@]}"; do
    mapfile -t members < <(printf '%s' "${groups[$key]}")
    for served in "${SERVED_DISTS[@]}"; do
      subset=()
      for member in "${members[@]}"; do
        entry_dist="${member%%$'\t'*}"
        if [ -z "$entry_dist" ] || [ "$entry_dist" = "$served" ]; then
          subset+=("${member#*$'\t'}")
        fi
      done
      [ "${#subset[@]}" -gt 0 ] || continue
      local -A kept_here=()
      while IFS= read -r path; do
        kept_here[$path]=1
        kept[$path]=1
      done < <(select_kept deb "${subset[@]}")
      for member in "${subset[@]}"; do
        path="${member##*$'\t'}"
        if [ -z "${kept_here[$path]:-}" ] && [ -z "$(deb_file_dist "$path")" ]; then
          DEB_INDEX_EXCLUDED[$served]+=" $(basename "$path")"
        fi
      done
      unset kept_here
    done
    for member in "${members[@]}"; do
      path="${member##*$'\t'}"
      if [ -z "${kept[$path]:-}" ]; then
        rm -f -- "$path"
        echo "Pruned $path (no served dist keeps it among its $KEEP_VERSIONS newest versions or $MAX_AGE_DAYS days)"
      fi
    done
  done
}

# prune_rpm_dir DIR: every package keeps its newest versions per architecture
# in DIR (a Fedora release directory or the SRPM one), as prune_group selects
# them. In the SRPM directory a source package built for a Fedora release the
# repository no longer serves is removed first.
prune_rpm_dir() {
  local dir="$1"
  [ -d "$dir" ] || return 0
  local -A groups=()
  local rpm_path info name arch evr built key
  while IFS= read -r -d '' rpm_path; do
    if [[ "$(basename "$rpm_path")" =~ \.fc([0-9]+)\.src\.rpm$ ]] \
        && ! rpm_release_served "${BASH_REMATCH[1]}"; then
      rm -f -- "$rpm_path"
      echo "Removed $rpm_path (fc${BASH_REMATCH[1]} is not served)"
      continue
    fi
    info=$(rpm -qp --nosignature --qf '%{NAME}\t%{ARCH}\t%{EPOCHNUM}:%{VERSION}-%{RELEASE}\t%{BUILDTIME}' "$rpm_path" 2>/dev/null) || continue
    IFS=$'\t' read -r name arch evr built <<< "$info"
    [[ "$built" =~ ^[0-9]+$ ]] || continue
    if ! rpm_evr_valid "$evr"; then
      echo "Error: $rpm_path has a version rpm does not allow: '$evr'" >&2
      exit 1
    fi
    key="$name|$arch"
    groups[$key]+="${evr}"$'\t'"${built}"$'\t'"${rpm_path}"$'\n'
  done < <(find "$dir" -maxdepth 1 -type f -name '*.rpm' -print0)
  local -a members
  for key in "${!groups[@]}"; do
    mapfile -t members < <(printf '%s' "${groups[$key]}")
    prune_group rpm "${members[@]}"
  done
}

# GPG signing helper
GPG_PASSPHRASE="${GPG_PASSPHRASE:-}"
gpg_sign() {
  if [ -n "$GPG_PASSPHRASE" ]; then
    local passfile
    local previous_trap
    passfile="$(mktemp)"
    cleanup_passfile() { rm -f "$passfile"; }
    previous_trap=$(trap -p EXIT || true)
    trap cleanup_passfile EXIT
    chmod 600 "$passfile"
    printf '%s' "$GPG_PASSPHRASE" > "$passfile"
    gpg --batch --yes --pinentry-mode loopback --passphrase-file "$passfile" "$@"
    trap - EXIT
    cleanup_passfile
    if [ -n "$previous_trap" ]; then
      eval "$previous_trap"
    fi
  else
    gpg --batch --yes "$@"
  fi
}

publish_deb() {
  for bin in apt-ftparchive dpkg-deb gpg gzip; do
    if ! command -v "$bin" >/dev/null 2>&1; then
      echo "Error: required command not found: $bin" >&2
      exit 1
    fi
  done

  local nullglob_state
  # shopt -p returns exit code 1 when the option is off; guard with || true.
  nullglob_state=$(shopt -p nullglob || true)
  shopt -s nullglob
  trap 'eval "$nullglob_state"' RETURN
  local debs=()
  if [ -d "$DEB_SRC_DIR" ]; then
    debs=("$DEB_SRC_DIR"/*.deb)
  else
    echo "DEB source dir not found: $DEB_SRC_DIR" >&2
  fi
  if [ ${#debs[@]} -eq 0 ]; then
    # No new debs this run — still fall through to index regeneration below,
    # so index-generation fixes take effect without waiting for new packages.
    echo "No new DEB packages to copy"
  fi

  for deb in "${debs[@]}"; do
    local pkgname first_letter pool_dir
    if ! pkgname=$(dpkg-deb -f "$deb" Package 2>/dev/null); then
      echo "Warning: failed to read package metadata from DEB: $deb" >&2
      echo "Skipping potentially corrupted or invalid DEB file." >&2
      continue
    fi
    if [ -z "$pkgname" ]; then
      echo "Warning: empty package name for DEB: $deb; skipping." >&2
      continue
    fi
    if ! [[ "$pkgname" =~ ^[a-z][a-z0-9+-]*$ ]]; then
      echo "Warning: invalid package name '$pkgname' for DEB: $deb; skipping." >&2
      continue
    fi
    local deb_dist
    deb_dist="$(deb_file_dist "$deb")"
    if [ -n "$deb_dist" ] && ! deb_dist_served "$deb_dist"; then
      echo "Warning: DEB built for $deb_dist, which is not served: $deb; skipping." >&2
      continue
    fi
    first_letter="${pkgname:0:1}"
    pool_dir="deb/pool/main/${first_letter}/${pkgname}"
    mkdir -p "$pool_dir"
    if [ -e "$pool_dir/$(basename "$deb")" ]; then
      echo "Warning: DEB already present in pool: $pool_dir/$(basename "$deb")" >&2
      continue
    fi
    # Use no-clobber copy to avoid races if the script is invoked concurrently.
    if ! cp -n "$deb" "$pool_dir/"; then
      echo "Warning: DEB copy skipped (already present): $pool_dir/$(basename "$deb")" >&2
      continue
    fi
    echo "Copied $deb to $pool_dir/"
  done

  # The indexes below list only what the pool keeps.
  prune_deb_pool

  local dist_dir dist
  # The names were validated with the settings, before anything changed.
  for dist in "${SERVED_DISTS[@]}"; do
    mkdir -p "deb/dists/$dist"
  done
  # A dist the repository no longer serves goes, indexes and all.
  for dist_dir in deb/dists/*; do
    [ -d "$dist_dir" ] || continue
    dist="$(basename "$dist_dir")"
    if ! deb_dist_served "$dist"; then
      rm -rf -- "$dist_dir"
      echo "Removed DEB dist $dist (not served)"
    fi
  done
  # apt-ftparchive fails on a missing pool; an empty one yields empty indexes.
  mkdir -p deb/pool/main
  if [ -d deb/dists ]; then
    # Served dist names: used to tell dist-specific debs (…_noble_amd64.deb)
    # from dist-agnostic ones (…_amd64.deb) which belong in every dist's index.
    local known_dists=""
    for dist in "${SERVED_DISTS[@]}"; do
      known_dists="${known_dists:+${known_dists}|}${dist}"
    done

    # Scan the pool ONCE per run, from inside deb/ so Filename comes out as
    # pool/… — apt resolves package URLs as <sources.list URI>/<Filename> and
    # the documented URI is https://repo.sw.foundation/deb. Scanning from the
    # repo root produced deb/pool/… paths, i.e. /deb/deb/… → 404 on fetch.
    local packages_all
    packages_all="$(mktemp)"
    if ! (cd deb && apt-ftparchive packages pool/main) > "$packages_all"; then
      rm -f "$packages_all"
      echo "Error: apt-ftparchive packages failed for deb/pool/main" >&2
      exit 1
    fi

    for dist_dir in deb/dists/*; do
      [ -d "$dist_dir" ] || continue
      dist="$(basename "$dist_dir")"

      # Every dist gets an index for each supported architecture so Release
      # advertises them and arm64 clients can resolve packages.
      local arch
      for arch in $DEB_ARCHS; do
        mkdir -p "$dist_dir/main/binary-$arch"
      done

      for arch_dir in "$dist_dir"/main/binary-*; do
        [ -d "$arch_dir" ] || continue
        arch="$(basename "$arch_dir" | sed 's/^binary-//')"
        if ! printf '%s' "$arch" | grep -Eq '^[A-Za-z0-9_-]+$'; then
          echo "Error: invalid arch name '$arch' for deb repository" >&2
          exit 1
        fi

        # Keep stanzas for this dist+arch only: dist-specific debs carry a
        # _<dist>_<arch>.deb suffix; dist-agnostic debs carry _<arch>.deb with
        # no dist token and are published to every dist. The stanza is matched
        # on the Filename field alone (paragraph mode), never on whole-stanza
        # regexes — a $-anchored whole-stanza match silently selects nothing
        # because Filename is not the last field (see #25).
        # A dist-agnostic file this dist no longer counts among its newest
        # versions is left out (see prune_deb_pool).
        if ! awk -v dist="$dist" -v arch="$arch" -v dists="$known_dists" \
            -v excluded="${DEB_INDEX_EXCLUDED[$dist]:-}" '
          BEGIN {
            RS=""; ORS="\n\n"
            n = split(excluded, names, " ")
            for (i = 1; i <= n; i++) skip[names[i]] = 1
          }
          {
            fn = ""
            n = split($0, lines, "\n")
            for (i = 1; i <= n; i++) {
              if (lines[i] ~ /^Filename: /) { fn = lines[i]; break }
            }
            if (fn == "") next
            sub(/^Filename: /, "", fn)
            sub(/^.*\//, "", fn)
            if (fn in skip) next
            if (fn ~ ("_" dist "_" arch "\\.(deb|ddeb|udeb)$")) { print; next }
            if (fn ~ ("_" arch "\\.(deb|ddeb|udeb)$") && fn !~ ("_(" dists ")_")) { print }
          }' "$packages_all" > "$arch_dir/Packages"; then
          rm -f "$packages_all"
          echo "Error: filtering Packages failed for dist '$dist' arch '$arch'" >&2
          exit 1
        fi
        # An empty Packages file is valid for a dist/arch that has no packages
        # yet — never fall back to the unfiltered pool here: that republishes
        # every dist's packages everywhere and lets apt pick a foreign-dist
        # stanza of the same version (see #25).

        gzip -kf "$arch_dir/Packages"
      done

      local arches
      arches=""
      for arch_dir in "$dist_dir"/main/binary-*; do
        [ -d "$arch_dir" ] || continue
        local arch_name
        arch_name="${arch_dir##*/binary-}"
        if ! printf '%s' "$arch_name" | grep -Eq '^[A-Za-z0-9_-]+$'; then
          echo "Error: invalid arch directory '$arch_name' for deb Release" >&2
          exit 1
        fi
        if [ -z "$arches" ]; then
          arches="$arch_name"
        else
          arches="$arches $arch_name"
        fi
      done
      if [ -z "$arches" ]; then
        arches="amd64"
      fi
      cat > "$dist_dir/Release" << EOF_RELEASE
Origin: sw.foundation
Label: sw.foundation
Suite: ${dist}
Codename: ${dist}
Architectures: ${arches}
Components: main
Description: sw.foundation Package Repository
EOF_RELEASE

      apt-ftparchive release "$dist_dir" >> "$dist_dir/Release"
      gpg_sign --armor --detach-sign -o "$dist_dir/Release.gpg" "$dist_dir/Release"
      if [ ! -s "$dist_dir/Release.gpg" ] || ! gpg --verify "$dist_dir/Release.gpg" "$dist_dir/Release" >/dev/null 2>&1; then
        echo "Error: Failed to create valid GPG signature for $dist_dir/Release (Release.gpg)" >&2
        exit 1
      fi
      gpg_sign --clearsign -o "$dist_dir/InRelease" "$dist_dir/Release"
      if [ ! -s "$dist_dir/InRelease" ] || ! gpg --verify "$dist_dir/InRelease" >/dev/null 2>&1; then
        echo "Error: Failed to create valid GPG clearsigned file for $dist_dir/Release (InRelease)" >&2
        exit 1
      fi

      echo "Updated DEB repository for ${dist}"
    done
    rm -f "$packages_all"
  fi
}

# The repository file the documented setup installs, served from each Fedora
# release directory. Its baseurl keeps dnf's literal $releasever, so a host
# upgraded to the next Fedora release follows that release's directory; it
# requires both package and metadata signatures, against the published key.
write_dnf_repo_file() {
  local fc_dir="$1"
  cat > "$fc_dir/sw.repo" << EOF_REPO
[sw-foundation]
name=sw.foundation packages (Fedora \$releasever)
baseurl=${REPO_BASE_URL}/rpm/fc\$releasever/
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=${REPO_BASE_URL}/keys/sw.asc
EOF_REPO
}

publish_rpm() {
  for bin in createrepo_c gpg rpm rpmsign; do
    if ! command -v "$bin" >/dev/null 2>&1; then
      echo "Error: required command not found: $bin" >&2
      exit 1
    fi
  done

  # Verify RPM signature; sign if missing. Operates on a temporary copy and
  # atomically replaces the target to avoid leaving corrupted packages on disk.
  ensure_rpm_signed() {
    local rpm_path="$1"
    local dir basename tmp_rpm
    dir=$(dirname "$rpm_path")
    basename=$(basename "$rpm_path")

    # Check both SIGPGP and SIGRSA — modern RPMs may use either tag.
    # || true: unsigned RPMs may error on missing tag rather than returning "(none)".
    local sig_pgp sig_rsa
    sig_pgp=$(rpm -qp --qf '%{SIGPGP:pgpsig}\n' "$rpm_path" 2>/dev/null || true)
    sig_rsa=$(rpm -qp --qf '%{SIGRSA:pgpsig}\n' "$rpm_path" 2>/dev/null || true)
    if { [ -z "$sig_pgp" ] || [ "$sig_pgp" = "(none)" ]; } &&
       { [ -z "$sig_rsa" ] || [ "$sig_rsa" = "(none)" ]; }; then
      # Dot-prefix hides temp file from glob patterns (*.rpm) so createrepo_c
      # won't index a half-written file. Atomic mv replaces original on success.
      tmp_rpm=$(mktemp -p "$dir" ".${basename}.XXXXXX")
      if ! cp "$rpm_path" "$tmp_rpm"; then
        rm -f "$tmp_rpm"
        echo "Error: failed to copy RPM for signing: $rpm_path" >&2
        exit 1
      fi
      if ! rpmsign --addsign "$tmp_rpm"; then
        rm -f "$tmp_rpm"
        echo "Error: failed to sign RPM: $rpm_path" >&2
        exit 1
      fi
      if ! mv -f "$tmp_rpm" "$rpm_path"; then
        rm -f "$tmp_rpm"
        echo "Error: failed to replace RPM with signed copy: $rpm_path" >&2
        exit 1
      fi
    fi

    # Three-tier verification: (1) exit code, (2) reject NOKEY/BAD/NOT OK,
    # (3) require OK. Grep patterns match the status portion of checksig output
    # ("file: digests signatures OK"), not filenames — RPM naming convention
    # (name-version-release.arch.rpm) won't produce false positives.
    local checksig_output
    if ! checksig_output=$(rpm --checksig "$rpm_path" 2>&1); then
      echo "Error: RPM signature verification failed: $rpm_path" >&2
      echo "rpm --checksig output: $checksig_output" >&2
      exit 1
    fi
    if printf '%s\n' "$checksig_output" | grep -Eq 'NOKEY|NOT OK|BAD'; then
      echo "Error: RPM has invalid or untrusted signature: $rpm_path" >&2
      echo "rpm --checksig output: $checksig_output" >&2
      exit 1
    fi
    if ! printf '%s\n' "$checksig_output" | grep -q 'OK'; then
      echo "Error: RPM signature not reported as OK: $rpm_path" >&2
      echo "rpm --checksig output: $checksig_output" >&2
      exit 1
    fi
  }

  local nullglob_state
  # shopt -p returns exit code 1 when the option is off; guard with || true.
  nullglob_state=$(shopt -p nullglob || true)
  shopt -s nullglob
  trap 'eval "$nullglob_state"' RETURN
  local rpms=()
  if [ -d "$RPM_SRC_DIR" ]; then
    rpms=("$RPM_SRC_DIR"/*.rpm)
  else
    echo "RPM source dir not found: $RPM_SRC_DIR" >&2
  fi
  if [ ${#rpms[@]} -eq 0 ]; then
    # No new RPMs this run: still fall through to the metadata update below,
    # so the release directories already served keep complete metadata and
    # their repository file, as the DEB side does.
    echo "No new RPM packages to copy"
  fi
  for rpm in "${rpms[@]}"; do
    local filename fc_ver dest_dir
    filename=$(basename "$rpm")
    # Only numeric Fedora versions are supported in repo layout.
    # RPM NEVRA: name-version-release.arch.rpm (name may contain hyphens).
    if [[ "$filename" =~ ^.+-[0-9][^-]*-[^-]*\.fc([0-9]+)\.[^.]+\.rpm$ ]]; then
      fc_ver="${BASH_REMATCH[1]}"
      if ! rpm_release_served "$fc_ver"; then
        echo "Warning: RPM built for fc${fc_ver}, which is not served: $filename; skipping" >&2
        continue
      fi
      dest_dir="rpm/fc${fc_ver}"
      mkdir -p "$dest_dir"
      # cp -n (no-clobber) + existence check: atomic guard against concurrent runs.
      # cp -n fails if file exists (coreutils 9.0+, ubuntu-latest has 9.4).
      # [ -e ] double-checks: catches permission/disk errors and older coreutils
      # where cp -n returned 0 on skip.
      if cp -n "$rpm" "$dest_dir/" 2>/dev/null && [ -e "$dest_dir/$filename" ]; then
        ensure_rpm_signed "$dest_dir/$filename"
        echo "Copied $rpm to $dest_dir/"
      else
        if [ ! -e "$dest_dir/$filename" ]; then
          echo "Error: failed to copy RPM and file does not exist at destination: $dest_dir/$filename" >&2
          exit 1
        fi
        echo "Warning: RPM already present; verifying signature: $dest_dir/$filename" >&2
        ensure_rpm_signed "$dest_dir/$filename"
      fi
    else
      echo "Warning: RPM file '$filename' does not match expected Fedora RPM pattern; skipping" >&2
    fi
  done

  # SRPMs
  local srpms=()
  if [ -d "$SRPM_SRC_DIR" ]; then
    srpms=("$SRPM_SRC_DIR"/*.rpm)
  fi
  if [ ${#srpms[@]} -gt 0 ]; then
    local srpm_dir="rpm/SRPMS"
    mkdir -p "$srpm_dir"
    for srpm in "${srpms[@]}"; do
      local srpm_name
      srpm_name=$(basename "$srpm")
      # Skipped before it is copied or signed, as binary RPMs are: a source
      # package for a retired release must not stop the served ones.
      if [[ "$srpm_name" =~ \.fc([0-9]+)\.src\.rpm$ ]] \
          && ! rpm_release_served "${BASH_REMATCH[1]}"; then
        echo "Warning: SRPM built for fc${BASH_REMATCH[1]}, which is not served: $srpm_name; skipping" >&2
        continue
      fi
      # Same cp -n + existence check pattern as RPM section above (see comment there).
      # Concurrency group in publish.yml prevents parallel runs.
      if cp -n "$srpm" "$srpm_dir/" 2>/dev/null && [ -e "$srpm_dir/$srpm_name" ]; then
        ensure_rpm_signed "$srpm_dir/$srpm_name"
        echo "Copied $srpm to $srpm_dir/"
      else
        if [ ! -e "$srpm_dir/$srpm_name" ]; then
          echo "Error: failed to copy SRPM and file does not exist at destination: $srpm_dir/$srpm_name" >&2
          exit 1
        fi
        echo "Warning: SRPM already present; verifying signature: $srpm_dir/$srpm_name" >&2
        ensure_rpm_signed "$srpm_dir/$srpm_name"
      fi
    done
  else
    echo "No SRPM packages found to copy"
  fi
  # The source directory is pruned and indexed on every run, as the release
  # directories are, so a publish without new SRPMs still retires old ones.
  if [ -d rpm/SRPMS ]; then
    prune_rpm_dir rpm/SRPMS
    createrepo_c --update rpm/SRPMS
    gpg_sign --armor --detach-sign -o rpm/SRPMS/repodata/repomd.xml.asc \
      rpm/SRPMS/repodata/repomd.xml
    if [ ! -s rpm/SRPMS/repodata/repomd.xml.asc ] || ! gpg --verify rpm/SRPMS/repodata/repomd.xml.asc rpm/SRPMS/repodata/repomd.xml >/dev/null 2>&1; then
      echo "Error: Failed to create valid GPG signature for SRPM repodata" >&2
      exit 1
    fi
    echo "Updated SRPM repository"
  fi

  # Update metadata for each rpm/fc* directory
  local fc_dir
  for fc_dir in rpm/fc*; do
    [ -d "$fc_dir" ] || continue
    # A Fedora release the repository no longer serves goes, metadata and all.
    if ! [[ "$(basename "$fc_dir")" =~ ^fc([0-9]+)$ ]] || ! rpm_release_served "${BASH_REMATCH[1]}"; then
      rm -rf -- "$fc_dir"
      echo "Removed RPM release directory $fc_dir (not served)"
      continue
    fi
    prune_rpm_dir "$fc_dir"
    if ls "$fc_dir"/*.rpm >/dev/null 2>&1; then
      createrepo_c --update "$fc_dir"
      gpg_sign --armor --detach-sign -o "$fc_dir/repodata/repomd.xml.asc" \
        "$fc_dir/repodata/repomd.xml"
      if [ ! -s "$fc_dir/repodata/repomd.xml.asc" ] || ! gpg --verify "$fc_dir/repodata/repomd.xml.asc" "$fc_dir/repodata/repomd.xml" >/dev/null 2>&1; then
        echo "Error: Failed to create valid GPG signature for $fc_dir repodata" >&2
        exit 1
      fi
      write_dnf_repo_file "$fc_dir"
      echo "Updated RPM repository for $(basename "$fc_dir")"
    fi
  done
}

publish_deb
publish_rpm
