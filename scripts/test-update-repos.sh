#!/usr/bin/env bash
# Exercises scripts/update-repos.sh against an EMPTY repository tree: no
# deb/dists, no deb/pool, no rpm/. That is the state after a key rotation
# clears the published packages, and it must still produce a complete,
# signed APT repository. Two throwaway debs cover the dist-agnostic and the
# dist-specific index paths.
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

REPO="$WORK/repo"
mkdir -p "$REPO/scripts" "$REPO/packages/deb"
cp "$ROOT_DIR/scripts/update-repos.sh" "$REPO/scripts/update-repos.sh"
chmod +x "$REPO/scripts/update-repos.sh"

# mkdeb NAME VERSION ARCH [DIST]
mkdeb() {
  local name="$1" ver="$2" arch="$3" dist="${4:-}"
  local d="$WORK/build/$name"
  mkdir -p "$d/DEBIAN" "$d/usr/share/doc/$name"
  printf 'Package: %s\nVersion: %s\nArchitecture: %s\nMaintainer: t <t@example.invalid>\nDescription: test\n' \
    "$name" "$ver" "$arch" > "$d/DEBIAN/control"
  echo test > "$d/usr/share/doc/$name/README"
  dpkg-deb -b "$d" "$REPO/packages/deb/${name}_${ver}${dist:+_$dist}_${arch}.deb" >/dev/null
}
mkdeb agnostic 1.0 amd64
mkdeb noblonly 1.0 amd64 noble

(cd "$REPO" && scripts/update-repos.sh)

fail() { echo "FAIL: $*" >&2; exit 1; }

for dist in bookworm jammy noble; do
  for arch in amd64 arm64; do
    [ -s "$REPO/deb/dists/$dist/main/binary-$arch/Packages.gz" ] \
      || fail "missing Packages.gz for $dist/$arch"
  done
  gpg --verify "$REPO/deb/dists/$dist/InRelease" >/dev/null 2>&1 \
    || fail "InRelease signature invalid for $dist"
  gpg --verify "$REPO/deb/dists/$dist/Release.gpg" "$REPO/deb/dists/$dist/Release" >/dev/null 2>&1 \
    || fail "Release.gpg signature invalid for $dist"
  grep -q '^Package: agnostic$' "$REPO/deb/dists/$dist/main/binary-amd64/Packages" \
    || fail "dist-agnostic package missing from $dist"
done
grep -q '^Package: noblonly$' "$REPO/deb/dists/noble/main/binary-amd64/Packages" \
  || fail "noble-specific package missing from noble"
if grep -q '^Package: noblonly$' "$REPO/deb/dists/bookworm/main/binary-amd64/Packages"; then
  fail "noble-specific package leaked into bookworm"
fi
grep -q '^Filename: pool/main/a/agnostic/agnostic_1.0_amd64.deb$' \
  "$REPO/deb/dists/jammy/main/binary-amd64/Packages" \
  || fail "Filename is not pool-relative"

echo "update-repos.sh: empty-tree publish OK"
