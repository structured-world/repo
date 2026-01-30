#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

umask 022

DEB_SRC_DIR="${DEB_SRC_DIR:-packages/deb}"
RPM_SRC_DIR="${RPM_SRC_DIR:-packages/rpm}"
SRPM_SRC_DIR="${SRPM_SRC_DIR:-packages/srpm}"

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

  if [ ! -d "$DEB_SRC_DIR" ]; then
    echo "DEB source dir not found: $DEB_SRC_DIR" >&2
    return 0
  fi

  local nullglob_state
  nullglob_state=$(shopt -p nullglob)
  shopt -s nullglob
  trap 'eval "$nullglob_state"' RETURN
  local debs=("$DEB_SRC_DIR"/*.deb)
  if [ ${#debs[@]} -eq 0 ]; then
    echo "No DEB packages to publish"
    return 0
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
    for dist_dir in deb/dists/*; do
      [ -d "$dist_dir" ] || continue
      dist="$(basename "$dist_dir")"
      if ! ls "$dist_dir"/main/binary-* >/dev/null 2>&1; then
        mkdir -p "$dist_dir/main/binary-amd64"
      fi

      for arch_dir in "$dist_dir"/main/binary-*; do
        [ -d "$arch_dir" ] || continue
        local arch
        arch="$(basename "$arch_dir" | sed 's/^binary-//')"
        if ! printf '%s' "$dist" | grep -Eq '^[A-Za-z0-9_-]+$'; then
          echo "Error: invalid dist name '$dist' for deb repository" >&2
          exit 1
        fi
        if ! printf '%s' "$arch" | grep -Eq '^[A-Za-z0-9_-]+$'; then
          echo "Error: invalid arch name '$arch' for deb repository" >&2
          exit 1
        fi

        # Generate Packages file - prefer dist-specific packages; fall back to all if empty.
        local packages_tmp
        packages_tmp="$(mktemp)"
        cleanup_packages_tmp() { rm -f "$packages_tmp"; }
        if ! apt-ftparchive packages "deb/pool/main" > "$packages_tmp"; then
          cleanup_packages_tmp
          echo "Error: apt-ftparchive packages failed for deb/pool/main" >&2
          exit 1
        fi
        if ! awk -v arch="$arch" 'BEGIN { RS=""; ORS="\n\n" } $0 ~ ("Filename: .*_" arch "\\.(deb|ddeb|udeb)$") { print }' \
          "$packages_tmp" > "$arch_dir/Packages"; then
          cleanup_packages_tmp
          echo "Error: filtering Packages failed for dist '$dist' arch '$arch'" >&2
          exit 1
        fi
        cleanup_packages_tmp

        if [ ! -s "$arch_dir/Packages" ]; then
          apt-ftparchive packages "deb/pool/main" > "$arch_dir/Packages"
        fi

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
Origin: SW Foundation
Label: SW Foundation
Suite: ${dist}
Codename: ${dist}
Architectures: ${arches}
Components: main
Description: SW Foundation Package Repository
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
  fi
}

publish_rpm() {
  for bin in createrepo_c gpg; do
    if ! command -v "$bin" >/dev/null 2>&1; then
      echo "Error: required command not found: $bin" >&2
      exit 1
    fi
  done

  if [ ! -d "$RPM_SRC_DIR" ]; then
    echo "RPM source dir not found: $RPM_SRC_DIR" >&2
    return 0
  fi

  local nullglob_state
  nullglob_state=$(shopt -p nullglob)
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
    # Expected pattern: name-version-release.fcNN.arch.rpm
    if [[ "$filename" =~ ^[^-]+-[0-9][^-]*-[^-]*\.fc([0-9]+)\.[^.]+\.rpm$ ]]; then
      fc_ver="${BASH_REMATCH[1]}"
      dest_dir="rpm/fc${fc_ver}"
      mkdir -p "$dest_dir"
      cp "$rpm" "$dest_dir/"
      echo "Copied $rpm to $dest_dir/"
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
      cp "$srpm" "$srpm_dir/"
      echo "Copied $srpm to $srpm_dir/"
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
