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
    passfile="$(mktemp)"
    cleanup_passfile() { rm -f "$passfile"; }
    trap cleanup_passfile RETURN
    chmod 600 "$passfile"
    printf '%s' "$GPG_PASSPHRASE" > "$passfile"
    gpg --batch --yes --pinentry-mode loopback --passphrase-file "$passfile" "$@"
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
  local debs=("$DEB_SRC_DIR"/*.deb)
  if [ ${#debs[@]} -eq 0 ]; then
    echo "No DEB packages to publish"
    eval "$nullglob_state"
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
    if ! [[ "$pkgname" =~ ^[a-z0-9][a-z0-9+.-]*$ ]]; then
      echo "Warning: invalid package name '$pkgname' for DEB: $deb; skipping." >&2
      continue
    fi
    first_letter="${pkgname:0:1}"
    pool_dir="deb/pool/main/${first_letter}/${pkgname}"
    mkdir -p "$pool_dir"
    cp "$deb" "$pool_dir/"
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
        local arch
        arch="$(basename "$arch_dir" | sed 's/^binary-//')"

        # Generate Packages file - prefer dist-specific packages; fall back to all if empty.
        apt-ftparchive packages "deb/pool/main" | \
          awk -v dist="$dist" -v arch="$arch" 'BEGIN { RS=""; ORS="\n\n" } $0 ~ ("Filename: .*_" dist "_" arch "\\.(deb|ddeb|udeb)") { print }' > "$arch_dir/Packages" || true

        if [ ! -s "$arch_dir/Packages" ]; then
          apt-ftparchive packages "deb/pool/main" > "$arch_dir/Packages"
        fi

        gzip -kf "$arch_dir/Packages"
      done

      local arches
      arches=$(ls -1d "$dist_dir"/main/binary-* 2>/dev/null | sed 's#.*/binary-##' | paste -sd ' ' -)
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
  eval "$nullglob_state"
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
  local rpms=("$RPM_SRC_DIR"/*.rpm)
  if [ ${#rpms[@]} -eq 0 ]; then
    echo "No RPM packages to publish"
    eval "$nullglob_state"
    return 0
  else
    for rpm in "${rpms[@]}"; do
      local filename fc_ver dest_dir
      filename=$(basename "$rpm")
      if [[ "$filename" =~ \.fc([0-9]+) ]]; then
        fc_ver="${BASH_REMATCH[1]}"
        dest_dir="rpm/fc${fc_ver}"
        mkdir -p "$dest_dir"
        cp "$rpm" "$dest_dir/"
        echo "Copied $rpm to $dest_dir/"
      else
        echo "Warning: RPM file '$filename' does not match expected '.fc[0-9]+.' pattern; skipping" >&2
      fi
    done
  fi

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
  local nullglob_fc_state
  nullglob_fc_state=$(shopt -p nullglob)
  shopt -s nullglob
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
  eval "$nullglob_fc_state"
  eval "$nullglob_state"
}

publish_deb
publish_rpm
