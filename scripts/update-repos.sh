#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

DEB_SRC_DIR="${DEB_SRC_DIR:-packages/deb}"
RPM_SRC_DIR="${RPM_SRC_DIR:-packages/rpm}"
SRPM_SRC_DIR="${SRPM_SRC_DIR:-packages/srpm}"

# GPG signing helper
GPG_PASSPHRASE="${GPG_PASSPHRASE:-}"
gpg_sign() {
  if [ -n "$GPG_PASSPHRASE" ]; then
    printf '%s' "$GPG_PASSPHRASE" | gpg --batch --yes --pinentry-mode loopback --passphrase-fd 0 "$@"
  else
    gpg --batch --yes "$@"
  fi
}

publish_deb() {
  if [ ! -d "$DEB_SRC_DIR" ]; then
    echo "DEB source dir not found: $DEB_SRC_DIR" >&2
    return 0
  fi

  shopt -s nullglob
  local debs=("$DEB_SRC_DIR"/*.deb)
  if [ ${#debs[@]} -eq 0 ]; then
    echo "No DEB packages to publish"
    return 0
  fi

  for deb in "${debs[@]}"; do
    local pkgname first_letter pool_dir
    pkgname=$(dpkg-deb -f "$deb" Package)
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
      mkdir -p "$dist_dir/main/binary-amd64"

      # Generate Packages file - prefer dist-specific packages
      apt-ftparchive packages "deb/pool/main" | \
        awk -v dist="$dist" 'BEGIN { RS=""; ORS="\\n\\n" } $0 ~ ("Filename: .*_" dist "_") { print }' > "$dist_dir/main/binary-amd64/Packages" || true

      if [ ! -s "$dist_dir/main/binary-amd64/Packages" ]; then
        apt-ftparchive packages "deb/pool/main" > "$dist_dir/main/binary-amd64/Packages"
      fi

      gzip -kf "$dist_dir/main/binary-amd64/Packages"

      cat > "$dist_dir/Release" << EOF_RELEASE
Origin: SW Foundation
Label: SW Foundation
Suite: ${dist}
Codename: ${dist}
Architectures: amd64
Components: main
Description: SW Foundation Package Repository
EOF_RELEASE

      apt-ftparchive release "$dist_dir" >> "$dist_dir/Release"
      gpg_sign --armor --detach-sign -o "$dist_dir/Release.gpg" "$dist_dir/Release"
      gpg_sign --clearsign -o "$dist_dir/InRelease" "$dist_dir/Release"

      echo "Updated DEB repository for ${dist}"
    done
  fi
}

publish_rpm() {
  if [ ! -d "$RPM_SRC_DIR" ]; then
    echo "RPM source dir not found: $RPM_SRC_DIR" >&2
    return 0
  fi

  shopt -s nullglob
  local rpms=("$RPM_SRC_DIR"/*.rpm)
  if [ ${#rpms[@]} -eq 0 ]; then
    echo "No RPM packages to publish"
  else
    for rpm in "${rpms[@]}"; do
      local filename fc_ver dest_dir
      filename=$(basename "$rpm")
      if [[ "$filename" =~ \.fc([0-9]+)\. ]]; then
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
  local srpms=("$SRPM_SRC_DIR"/*.rpm)
  if [ -d "$SRPM_SRC_DIR" ] && [ ${#srpms[@]} -gt 0 ]; then
    local srpm_dir="rpm/SRPMS"
    mkdir -p "$srpm_dir"
    for srpm in "${srpms[@]}"; do
      cp "$srpm" "$srpm_dir/"
      echo "Copied $srpm to $srpm_dir/"
    done

    createrepo_c --update "$srpm_dir"
    gpg_sign --armor --detach-sign -o "$srpm_dir/repodata/repomd.xml.asc" \
      "$srpm_dir/repodata/repomd.xml"
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
      echo "Updated RPM repository for $(basename "$fc_dir")"
    fi
  done
}

publish_deb
publish_rpm
