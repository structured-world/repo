# SW Foundation Package Repository

Package repository for Structured World Foundation software. Hosts signed RPM and DEB packages for modern Linux distributions.

**Site:** [repo.sw.foundation](https://repo.sw.foundation)

## How It Works

Source projects provide a `manifest.json` describing their packages, platforms, and documentation. CI uploads these as a `repo-meta-<project>` artifact; the publish workflow copies them into `packages/meta/<project>/` where `build-docs.py` discovers and renders them.

```
source-repo/                           repo (during publish)
  packaging/                           packages/meta/<project>/
    manifest.json  ──CI artifact──→      manifest.json
    docs/                                docs/
      setup-guide.md                       setup-guide.md
```

See [manifests/strongswan/manifest.json](manifests/strongswan/manifest.json) for an example (also used as committed fallback).

## Quick Install

### Fedora (RPM)

```bash
sudo dnf config-manager --add-repo \
  https://repo.sw.foundation/rpm/fc$(rpm -E %fedora)/sw.repo

sudo dnf install <package-name>
```

### Ubuntu / Debian (DEB)

```bash
# Add GPG key
curl -fsSL https://repo.sw.foundation/keys/sw.gpg \
  | sudo gpg --dearmor -o /etc/apt/keyrings/sw.gpg

# Add repository
echo "deb [signed-by=/etc/apt/keyrings/sw.gpg] \
  https://repo.sw.foundation/deb $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/sw.list

sudo apt update
sudo apt install <package-name>
```

## GPG Key

All packages are signed with our GPG key.

| Property | Value |
|----------|-------|
| Key ID | `A187D55B5A043632` |
| Fingerprint | `4AC4 06DA 15C9 BE4D C1A0 2343 A187 D55B 5A04 3632` |
| Algorithm | Ed25519 |

```bash
curl -fsSL https://repo.sw.foundation/keys/sw.gpg | gpg --import
```

## Adding a New Project

1. Create `packaging/manifest.json` in your source repo (see [manifests/strongswan/manifest.json](manifests/strongswan/manifest.json) for the format)
2. Add optional `packaging/docs/*.md` for documentation pages
3. Upload `manifest.json` and `docs/` as a `repo-meta-<project>` artifact in your CI workflow (the artifact root should contain `manifest.json` directly, not a `packaging/` subdirectory)
4. Add a new workflow input and download step in `publish.yml` for the project
5. Trigger the publish workflow — `build-docs.py` auto-discovers all manifests in `packages/meta/*/`

## Links

- [SW Foundation](https://sw.foundation)
- [Repository Source](https://github.com/structured-world/repo)

## Maintainer

Dmitry Prudnikov <mail@polaz.com>
