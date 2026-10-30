# sw.foundation Package Repository

Package repository for software maintained by Dmitry Prudnikov and contributors. Hosts signed RPM and DEB packages for modern Linux distributions.

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

## Codex plugin marketplace

The shared marketplace is `.agents/plugins/marketplace.json`, named `sw-foundation`.
Its [plugin catalog](https://repo.sw.foundation/plugins/) shows only verified,
published releases. Add the source once with Codex CLI:

```bash
codex plugin marketplace add structured-world/repo --sparse .agents/plugins
```

Then use **Install in Codex** on a plugin card, or install its identifier from the
CLI, for example `codex plugin add gitlab-mcp@sw-foundation` after its first eligible
release. Installation links open the host's confirmation flow only for a known
marketplace. They do not import a ZIP or authorize an account. GitLab MCP requires
Node.js 24+ and supports configuring either a local GitLab connection or an existing
MCP server after installation, through its private connection panel.

To refresh the catalog, run `codex plugin marketplace upgrade sw-foundation`, then
review plugin updates in Codex. Plugin sources are pinned to verified commits.
Standalone ZIP downloads and their checksums remain in the source project's GitHub
release. Claude Desktop MCPB bundles and Claude Code configuration are separate.

### Publisher and recovery

GitLab MCP's release workflow sends `refresh-gitlab-mcp-plugin` to this repository
only after npm, release assets and its other publication steps succeed. The
`Publish Plugin Marketplace` workflow verifies that exact released tag, so a newer
unfinished release cannot hide the completed publication. Dispatch payloads cannot
select arbitrary source repositories or commits. Manual dispatch can specify a
tag or leave it empty to reconcile the latest stable release. The
release app must already be installed on both repositories with Contents write
permission. The existing `RELEASER_APP_ID` and `RELEASER_APP_PRIVATE_KEY` secrets
provide its identity; the catalog does not use package-signing secrets.

Before changing the entry, `scripts/plugin-marketplace.py` verifies the source
manifest and pinned npm launcher, the published npm binary, and the standalone
ZIP against its SHA-256 sidecar. It stores the verified public listing metadata
under `manifests/plugins/` and commits it with the catalog and rendered page.
Incomplete, inconsistent or changed publications fail without replacing the live
catalog. Older releases cannot downgrade an existing entry. Repeating the workflow
is safe; use its manual dispatch to reconcile after a failed notification or a
concurrent branch update. It does not create or publish a source release.

The plugin publisher shares the package publisher's concurrency group. It invokes
`scripts/build-docs.py --plugins-only`, updating shared navigation while preserving
existing package and documentation content and sitemap metadata. Normal site generation also renders the plugin page.
Its sparse checkout does not download the APT/RPM package tree.
The initial catalog is empty until the configurable GitLab MCP release is available.

Validate changes with Python 3.11+:

```bash
python3 -B scripts/test-plugin-marketplace.py
python3 -B scripts/test-plugin-catalog.py
uv run --with 'markdown>=3.6,<4' python -B scripts/test-build-docs.py
python3 -B scripts/qualify-codex-marketplace.py --codex /path/to/codex
```

CLI and fixture checks do not establish desktop UI qualification or public release
availability. Verify those against the released package before advertising them.

## Tetherloom publication artifacts

Tetherloom Actions artifacts are temporary transfer files. After signing and
pushing the repository output, the publisher deletes only the artifact IDs
recorded for that release attempt. The download token stays read-only; cleanup
uses a separate token restricted to Actions write access on Tetherloom. The
release application must have that permission granted in its installation.

The same commit stores a minimal receipt under `.publications/tetherloom/`.
Repeated delivery of an already published attempt skips the artifact download
and resumes cleanup from current `main`, even if the source has started or failed
a newer attempt. A failed push does not authorize deletion, and a failed
deletion remains a visible workflow failure that can be retried. A new source
attempt is independent; artifacts uploaded after the recorded snapshot are
never swept into an older cleanup. Published signed packages and release assets
remain available; Actions retention is only a fallback for abandoned transfers.
Dispatches identify the source attempt explicitly. Older dispatches without an
attempt can be retried after the source run completes successfully; they cannot
admit an unfinished rerun based on an earlier attempt's notification.

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
  | sudo tee /etc/apt/keyrings/sw.gpg >/dev/null

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
curl -fsSL https://repo.sw.foundation/keys/sw.asc | gpg --import
```

## Adding a New Project

1. Create `packaging/manifest.json` in your source repo (see [manifests/strongswan/manifest.json](manifests/strongswan/manifest.json) for the format)
2. Add optional `packaging/docs/*.md` for documentation pages
3. Upload `manifest.json` and `docs/` as a `repo-meta-<project>` artifact in your CI workflow (the artifact root should contain `manifest.json` directly, not a `packaging/` subdirectory)
4. Add a new workflow input and download step in `publish.yml` for the project
5. Trigger the publish workflow — `build-docs.py` auto-discovers all manifests in `packages/meta/*/`

## Links

- [sw.foundation](https://sw.foundation)
- [Repository Source](https://github.com/structured-world/repo)

## Maintainer

Dmitry Prudnikov <mail@polaz.com>
