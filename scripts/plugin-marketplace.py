#!/usr/bin/env python3
"""Refresh the shared marketplace from a fully published GitLab MCP release."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import tempfile
import tarfile
import urllib.error
import urllib.parse
import urllib.request
import zipfile

REPOSITORY = "structured-world/gitlab-mcp"
PREFIX = f"/repos/{REPOSITORY}"
PACKAGE = "@structured-world/gitlab-mcp"
PLUGIN = "gitlab-mcp"
ARCHIVE = "gitlab-mcp-codex.zip"
SOURCE_PATH = "plugins/gitlab-mcp"


class Client:
    """Authenticate API requests only; public downloads never receive the token."""

    def json(self, path):
        request = urllib.request.Request("https://api.github.com" + path, headers={
            "Authorization": "Bearer " + os.environ["GH_TOKEN"],
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        })
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)

    def npm_json(self, version):
        url = f"https://registry.npmjs.org/{urllib.parse.quote(PACKAGE, safe='@')}/{version}"
        with urllib.request.urlopen(url, timeout=30) as response:
            return json.load(response)

    def download(self, url, destination):
        # Release download redirects can leave github.com; never attach API credentials.
        with urllib.request.urlopen(url, timeout=30) as response:
            while chunk := response.read(1024 * 1024):
                destination.write(chunk)


def version(value):
    """Stable release versions compare numerically, independently of notification order."""
    if not isinstance(value, str) or not re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", value):
        raise ValueError("Expected a stable semantic version")
    return tuple(int(part) for part in value.split("."))


def source_file(client, path, commit):
    response = client.json(f"{PREFIX}/contents/{path}?ref={commit}")
    if response["type"] != "file" or response["encoding"] != "base64":
        raise ValueError("Source metadata is not a file")
    return json.loads(base64.b64decode(response["content"]))


def verify_npm_executable(client, npm):
    """Check the published bytes without extracting or executing source-repository code."""
    binary = PurePosixPath(npm['bin']['gitlab-mcp-plugin'])
    if binary.is_absolute() or '..' in binary.parts:
        raise ValueError('The npm executable must be package-relative')
    expected_url = f'https://registry.npmjs.org/@structured-world/gitlab-mcp/-/gitlab-mcp-{npm["version"]}.tgz'
    distribution = npm.get('dist', {})
    integrity = distribution.get('integrity')
    if (distribution.get('tarball') != expected_url or not isinstance(integrity, str)
            or not re.fullmatch(r'sha512-[A-Za-z0-9+/]{86}==', integrity)):
        raise ValueError('The npm distribution metadata is incomplete')
    digest = base64.b64decode(integrity.removeprefix('sha512-'), validate=True)
    with tempfile.TemporaryFile() as artifact:
        client.download(expected_url, artifact)
        artifact.seek(0)
        if hashlib.file_digest(artifact, 'sha512').digest() != digest:
            raise ValueError('The npm distribution integrity does not match')
        artifact.seek(0)
        try:
            with tarfile.open(fileobj=artifact, mode='r|gz') as archive:
                for member in archive:
                    if member.name == 'package/' + str(binary):
                        if member.isfile() and member.size > 0:
                            return
                        break
        except tarfile.TarError as error:
            raise ValueError('The npm distribution archive is invalid') from error
    raise ValueError('The declared npm executable is missing or empty')


def candidate(client, release_tag=None):
    """Verify all distribution paths before returning publishable metadata."""
    if release_tag is None:
        release = client.json(f"{PREFIX}/releases/latest")
    else:
        if not release_tag.startswith("gitlab-mcp-v"):
            raise ValueError("Expected a GitLab MCP release tag")
        version(release_tag.removeprefix("gitlab-mcp-v"))
        release = client.json(f"{PREFIX}/releases/tags/{urllib.parse.quote(release_tag, safe='')}")
        if release["tag_name"] != release_tag:
            raise ValueError("Release response differs from the requested tag")
    tag = release["tag_name"]
    if release["draft"] or release["prerelease"] or not tag.startswith("gitlab-mcp-v"):
        raise ValueError("Expected a published stable GitLab MCP release")
    released_version = tag.removeprefix("gitlab-mcp-v")
    version(released_version)
    commit = client.json(f"{PREFIX}/commits/{urllib.parse.quote(tag, safe='')}")["sha"]
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("Release does not resolve to an immutable commit")
    manifest = source_file(client, f"{SOURCE_PATH}/plugin.json", commit)
    if manifest["name"] != PLUGIN or manifest["version"] != released_version:
        raise ValueError("Source plugin version differs from the release")
    interface = manifest.get('extensions')
    for field in ('com.openai', 'interface'):
        if not isinstance(interface, dict):
            break
        interface = interface.get(field)
    if (not isinstance(interface, dict)
            or any(not isinstance(interface.get(field), str) or not interface[field].strip()
                   for field in ('displayName', 'shortDescription'))):
        raise ValueError('Source plugin lacks Codex interface metadata')
    launcher = source_file(client, f"{SOURCE_PATH}/mcp.json", commit)["mcpServers"]["gitlab-sw"]
    expected_args = ["-y", "--package", f"{PACKAGE}@{released_version}",
                     "gitlab-mcp-plugin", "${PLUGIN_DATA}"]
    if (launcher.get("type") != "stdio" or launcher.get("command") != "npx"
            or launcher.get("args") != expected_args):
        raise ValueError("Source launcher does not select the released configurable runtime")
    npm = client.npm_json(released_version)
    if (npm["name"] != PACKAGE or npm["version"] != released_version
            or not npm.get("bin", {}).get("gitlab-mcp-plugin")
            or not isinstance(npm["bin"]["gitlab-mcp-plugin"], str)
            or not isinstance(npm.get("engines", {}).get("node"), str)):
        raise ValueError("The released npm connector is unavailable")
    verify_npm_executable(client, npm)

    release_url = f"https://github.com/{REPOSITORY}/releases/tag/{tag}"
    if release["html_url"] != release_url:
        raise ValueError("Unexpected release location")
    asset_root = f"https://github.com/{REPOSITORY}/releases/download/{tag}/"
    assets = {}
    for name in (ARCHIVE, ARCHIVE + ".sha256"):
        matches = [asset for asset in release["assets"] if asset["name"] == name]
        if (len(matches) != 1 or matches[0]["state"] != "uploaded" or matches[0]["size"] <= 0
                or matches[0]["browser_download_url"] != asset_root + name):
            raise ValueError("The release marketplace archive and checksum must both be uploaded")
        assets[name] = matches[0]["browser_download_url"]

    with tempfile.TemporaryFile() as sidecar:
        client.download(assets[ARCHIVE + ".sha256"], sidecar)
        sidecar.seek(0)
        match = re.fullmatch(rb"([0-9a-f]{64})  gitlab-mcp-codex\.zip\n", sidecar.read(1024))
        if match is None or sidecar.read(1):
            raise ValueError("Invalid marketplace checksum file")
        checksum = match[1].decode("ascii")
    with tempfile.TemporaryFile() as artifact:
        client.download(assets[ARCHIVE], artifact)
        artifact.seek(0)
        if hashlib.file_digest(artifact, "sha256").hexdigest() != checksum:
            raise ValueError("Marketplace archive checksum mismatch")
        artifact.seek(0)
        try:
            with zipfile.ZipFile(artifact) as archive:
                exported = json.loads(archive.read('.agents/plugins/marketplace.json'))
                entries = exported['plugins']
                if (exported['name'] != PLUGIN or len(entries) != 1 or entries[0]['name'] != PLUGIN
                        or entries[0]['source'] != {'source': 'local', 'path': './' + SOURCE_PATH}):
                    raise ValueError('Release archive does not contain an installable marketplace')
                if json.loads(archive.read(f"{SOURCE_PATH}/plugin.json")) != manifest:
                    raise ValueError("Archive manifest differs from the immutable source")
                embedded = json.loads(archive.read(f"{SOURCE_PATH}/mcp.json"))["mcpServers"]["gitlab-sw"]
                if (embedded.get("type") != "stdio" or embedded.get("command") != "node"
                        or embedded.get("args") != ["${PLUGIN_ROOT}/runtime/src/plugin/main.js", "${PLUGIN_DATA}"]):
                    raise ValueError("Release archive does not contain the standalone connector")
                if archive.getinfo(f"{SOURCE_PATH}/runtime/src/plugin/main.js").file_size == 0:
                    raise ValueError('Release archive has an empty connector runtime')
        except (KeyError, zipfile.BadZipFile, json.JSONDecodeError) as error:
            raise ValueError("Release archive is incomplete") from error

    entry = {
        "name": PLUGIN,
        "source": {"source": "git-subdir", "url": f"https://github.com/{REPOSITORY}.git",
                   "path": "./" + SOURCE_PATH, "sha": commit},
        "policy": {"installation": "AVAILABLE", "authentication": "ON_INSTALL"},
        "category": "Developer Tools",
    }
    snapshot = {"source": entry['source'], "release": release_url, "download": assets[ARCHIVE],
                "checksum": assets[ARCHIVE + ".sha256"], "sha256": checksum, "manifest": manifest,
                "runtime": {"node": npm["engines"]["node"]}}
    return entry, snapshot


def encoded(value):
    return (json.dumps(value, indent=2, ensure_ascii=False) + "\n").encode()


def refresh(root, client, release_tag=None):
    """Change only this plugin's entry; Git publication commits both outputs together."""
    catalog_path = root / ".agents/plugins/marketplace.json"
    catalog = json.loads(catalog_path.read_text())
    snapshot_path = root / f"manifests/plugins/{PLUGIN}.json"
    entry, snapshot = candidate(client, release_tag)
    if snapshot_path.exists():
        previous = json.loads(snapshot_path.read_text())
        previous_version = version(previous["manifest"]["version"])
        selected_version = version(snapshot["manifest"]["version"])
        if selected_version < previous_version:
            return False
        if selected_version == previous_version and previous != snapshot:
            raise ValueError("An already published plugin version has changed")
    plugins = []
    found = False
    for value in catalog["plugins"]:
        if value["name"] == PLUGIN:
            if found:
                raise ValueError("Duplicate GitLab plugin entries in the catalog")
            found = True
            # Ordering and install policy belong to the shared catalog, not the source release.
            plugins.append({**value, "source": entry["source"]})
        else:
            plugins.append(value)
    if not found:
        plugins.append(entry)
    catalog["plugins"] = plugins
    outputs = {catalog_path: encoded(catalog), snapshot_path: encoded(snapshot)}
    changed = any(not path.exists() or path.read_bytes() != content for path, content in outputs.items())
    if changed:
        for path, content in outputs.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)
    return changed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--release-tag", help="Published GitLab MCP tag; omit for manual latest-release reconciliation")
    args = parser.parse_args()
    try:
        changed = refresh(args.root, Client(), args.release_tag)
    except (ValueError, KeyError, OSError, urllib.error.URLError) as error:
        # API bodies and authorization headers do not belong in publication diagnostics.
        if isinstance(error, urllib.error.HTTPError):
            parser.exit(1, f"Plugin publication failed: HTTP {error.code}\n")
        if type(error) is ValueError:
            parser.exit(1, f"Plugin publication failed: {error}\n")
        parser.exit(1, f"Plugin publication failed: {type(error).__name__}\n")
    print("Marketplace updated" if changed else "Marketplace already current")


if __name__ == "__main__":
    main()
