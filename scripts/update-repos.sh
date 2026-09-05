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

  local dist_dir dist
  if [ -d deb/dists ]; then
    # Known dist names — used to tell dist-specific debs (…_noble_amd64.deb)
    # from dist-agnostic ones (…_amd64.deb, e.g. coordinode) which belong in
    # every dist's index.
    local known_dists=""
    for dist_dir in deb/dists/*; do
      [ -d "$dist_dir" ] || continue
      dist="$(basename "$dist_dir")"
      if ! printf '%s' "$dist" | grep -Eq '^[A-Za-z0-9_-]+$'; then
        echo "Error: invalid dist name '$dist' for deb repository" >&2
        exit 1
      fi
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
        if ! awk -v dist="$dist" -v arch="$arch" -v dists="$known_dists" '
          BEGIN { RS=""; ORS="\n\n" }
          {
            fn = ""
            n = split($0, lines, "\n")
            for (i = 1; i <= n; i++) {
              if (lines[i] ~ /^Filename: /) { fn = lines[i]; break }
            }
            if (fn == "") next
            sub(/^Filename: /, "", fn)
            sub(/^.*\//, "", fn)
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

  if [ ! -d "$RPM_SRC_DIR" ]; then
    echo "RPM source dir not found: $RPM_SRC_DIR" >&2
    return 0
  fi

  local nullglob_state
  # shopt -p returns exit code 1 when the option is off; guard with || true.
  nullglob_state=$(shopt -p nullglob || true)
  shopt -s nullglob
  trap 'eval "$nullglob_state"' RETURN
  local rpms=("$RPM_SRC_DIR"/*.rpm)
  if [ ${#rpms[@]} -eq 0 ]; then
    echo "No RPM packages to publish"
    return 0
  fi
  for rpm in "${rpms[@]}"; do
    local filename fc_ver dest_dir
    filename=$(basename "$rpm")
    # Only numeric Fedora versions are supported in repo layout.
    # RPM NEVRA: name-version-release.arch.rpm (name may contain hyphens).
    if [[ "$filename" =~ ^.+-[0-9][^-]*-[^-]*\.fc([0-9]+)\.[^.]+\.rpm$ ]]; then
      fc_ver="${BASH_REMATCH[1]}"
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

    createrepo_c --update "$srpm_dir"
    gpg_sign --armor --detach-sign -o "$srpm_dir/repodata/repomd.xml.asc" \
      "$srpm_dir/repodata/repomd.xml"
    if [ ! -s "$srpm_dir/repodata/repomd.xml.asc" ] || ! gpg --verify "$srpm_dir/repodata/repomd.xml.asc" "$srpm_dir/repodata/repomd.xml" >/dev/null 2>&1; then
      echo "Error: Failed to create valid GPG signature for SRPM repodata" >&2
      exit 1
    fi
    echo "Updated SRPM repository"
  else
    echo "No SRPM packages found to copy"
  fi

  # Update metadata for each rpm/fc* directory
  local fc_dir
  for fc_dir in rpm/fc*; do
    [ -d "$fc_dir" ] || continue
    if ls "$fc_dir"/*.rpm >/dev/null 2>&1; then
      createrepo_c --update "$fc_dir"
      gpg_sign --armor --detach-sign -o "$fc_dir/repodata/repomd.xml.asc" \
        "$fc_dir/repodata/repomd.xml"
      if [ ! -s "$fc_dir/repodata/repomd.xml.asc" ] || ! gpg --verify "$fc_dir/repodata/repomd.xml.asc" "$fc_dir/repodata/repomd.xml" >/dev/null 2>&1; then
        echo "Error: Failed to create valid GPG signature for $fc_dir repodata" >&2
        exit 1
      fi
      echo "Updated RPM repository for $(basename "$fc_dir")"
    fi
  done
}

publish_deb
publish_rpm
