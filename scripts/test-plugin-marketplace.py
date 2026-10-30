#!/usr/bin/env python3
"""Release refresh checks: incomplete publications must not replace working entries."""
import base64
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import tarfile
import unittest
from unittest.mock import patch
import zipfile

SPEC = importlib.util.spec_from_file_location(
    "plugin_marketplace", Path(__file__).with_name("plugin-marketplace.py"))
marketplace = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(marketplace)


class ReleaseFixture:
    """Serve the same metadata and archive boundaries as the public release APIs."""

    def __init__(self, version="13.0.0"):
        self.version = version
        self.commit = "a" * 40
        self.tag = "gitlab-mcp-v" + version
        self.release_url = f"https://github.com/structured-world/gitlab-mcp/releases/tag/{self.tag}"
        self.asset_root = f"https://github.com/structured-world/gitlab-mcp/releases/download/{self.tag}/"
        self.manifest = {
            "name": "gitlab-mcp", "version": version, "description": "GitLab tools",
            "extensions": {"com.openai": {"interface": {
                "displayName": "GitLab", "shortDescription": "Projects and merge requests"}}},
        }
        self.launcher = {"mcpServers": {"gitlab-sw": {
            "type": "stdio", "command": "npx", "cwd": "${PLUGIN_ROOT}",
            "args": ["-y", "--package", f"@structured-world/gitlab-mcp@{version}",
                     "gitlab-mcp-plugin", "${PLUGIN_DATA}"],
        }}}
        embedded = {"mcpServers": {"gitlab-sw": {
            "type": "stdio", "command": "node",
            "args": ["${PLUGIN_ROOT}/runtime/src/plugin/main.js", "${PLUGIN_DATA}"],
        }}}
        stream = io.BytesIO()
        with zipfile.ZipFile(stream, "w") as archive:
            archive.writestr('.agents/plugins/marketplace.json', json.dumps({
                'name': 'gitlab-mcp', 'plugins': [{'name': 'gitlab-mcp',
                    'source': {'source': 'local', 'path': './plugins/gitlab-mcp'}}]}))
            archive.writestr("plugins/gitlab-mcp/plugin.json", json.dumps(self.manifest))
            archive.writestr("plugins/gitlab-mcp/mcp.json", json.dumps(embedded))
            archive.writestr("plugins/gitlab-mcp/runtime/src/plugin/main.js", "// fixture\n")
        self.archive = stream.getvalue()
        self.checksum = hashlib.sha256(self.archive).hexdigest()
        self.sidecar = f"{self.checksum}  gitlab-mcp-codex.zip\n".encode()
        self.release = {
            "draft": False, "prerelease": False, "tag_name": self.tag,
            "html_url": self.release_url,
            "assets": [{"name": name, "state": "uploaded", "size": size,
                        "browser_download_url": self.asset_root + name}
                       for name, size in (("gitlab-mcp-codex.zip", len(self.archive)),
                                          ("gitlab-mcp-codex.zip.sha256", len(self.sidecar)))],
        }
        self.npm = {"name": "@structured-world/gitlab-mcp", "version": version,
                    "bin": {"gitlab-mcp-plugin": "dist/src/plugin/main.js"},
                    "engines": {"node": ">=24"}}
        self.npm_url = f'https://registry.npmjs.org/@structured-world/gitlab-mcp/-/gitlab-mcp-{version}.tgz'
        self.pack_npm()

    def pack_npm(self, include_binary=True):
        stream = io.BytesIO()
        metadata = {key: value for key, value in self.npm.items() if key != 'dist'}
        with tarfile.open(fileobj=stream, mode='w:gz') as archive:
            files = {'package/package.json': json.dumps(metadata).encode()}
            if include_binary:
                files['package/dist/src/plugin/main.js'] = b'// fixture connector\n'
            for name, content in files.items():
                info = tarfile.TarInfo(name)
                info.size = len(content)
                archive.addfile(info, io.BytesIO(content))
        self.npm_archive = stream.getvalue()
        integrity = base64.b64encode(hashlib.sha512(self.npm_archive).digest()).decode()
        self.npm['dist'] = {'tarball': self.npm_url, 'integrity': 'sha512-' + integrity}

    def json(self, path):
        if path.endswith("/releases/latest") or path.endswith("/releases/tags/" + self.tag):
            return self.release
        if "/commits/" in path:
            return {"sha": self.commit}
        if "/contents/" in path:
            if f"ref={self.commit}" not in path:
                raise AssertionError("Source metadata must use the resolved immutable commit")
            value = self.manifest if "/plugin.json?" in path else self.launcher
            return {"type": "file", "encoding": "base64",
                    "content": base64.b64encode(json.dumps(value).encode()).decode()}
        raise AssertionError(path)

    def npm_json(self, version):
        if version != self.version:
            raise AssertionError(version)
        return self.npm

    def download(self, url, destination):
        if url == self.npm_url:
            destination.write(self.npm_archive)
            return
        if not url.startswith(self.asset_root):
            raise AssertionError(url)
        destination.write(self.sidecar if url.endswith(".sha256") else self.archive)


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.catalog = self.root / ".agents/plugins/marketplace.json"
        self.catalog.parent.mkdir(parents=True)
        self.catalog.write_text(json.dumps({
            "name": "sw-foundation", "plugins": [{"name": "another-plugin"}]}))

    def refresh(self, fixture):
        return marketplace.refresh(self.root, fixture)

    def test_complete_release_pins_source_and_retains_other_entries(self):
        # Publication must select the verified commit, keeping unrelated plugins intact.
        fixture = ReleaseFixture()
        self.assertTrue(self.refresh(fixture))
        catalog = json.loads(self.catalog.read_text())
        self.assertEqual(catalog["plugins"][0], {"name": "another-plugin"})
        entry = catalog["plugins"][1]
        self.assertEqual(entry["source"], {
            "source": "git-subdir", "url": "https://github.com/structured-world/gitlab-mcp.git",
            "path": "./plugins/gitlab-mcp", "sha": fixture.commit,
        })
        snapshot = json.loads((self.root / "manifests/plugins/gitlab-mcp.json").read_text())
        self.assertEqual(snapshot["manifest"], fixture.manifest)
        self.assertEqual(snapshot["commit"], fixture.commit)
        self.assertEqual(snapshot["sha256"], fixture.checksum)

    def test_declared_but_missing_npm_executable_is_rejected(self):
        # Registry bin metadata cannot establish that the downloadable package can launch.
        fixture = ReleaseFixture()
        fixture.pack_npm(include_binary=False)
        before = self.catalog.read_bytes()
        with self.assertRaisesRegex(ValueError, 'executable'):
            self.refresh(fixture)
        self.assertEqual(self.catalog.read_bytes(), before)

    def test_retry_is_byte_identical_and_old_refresh_does_not_downgrade(self):
        # Duplicate notifications and delayed releases must preserve the selected version.
        self.refresh(ReleaseFixture("13.1.0"))
        before = self.catalog.read_bytes()
        self.assertFalse(self.refresh(ReleaseFixture("13.1.0")))
        self.assertFalse(self.refresh(ReleaseFixture("13.0.0")))
        self.assertEqual(self.catalog.read_bytes(), before)

    def test_incomplete_or_inconsistent_release_preserves_existing_catalog(self):
        # Every verification happens before either committed input can change.
        self.refresh(ReleaseFixture())
        before = {p.relative_to(self.root): p.read_bytes()
                  for p in self.root.rglob("*.json")}
        for change in ("missing_asset", "checksum", "source_version", "npm_version",
                       "npm_binary", "source_launcher", "archive_manifest", "draft"):
            with self.subTest(change=change):
                fixture = ReleaseFixture("13.1.0")
                if change == "missing_asset":
                    fixture.release["assets"].pop()
                elif change == "checksum":
                    fixture.sidecar = b"0" * 64 + b"  gitlab-mcp-codex.zip\n"
                elif change == "source_version":
                    fixture.manifest["version"] = "13.0.0"
                elif change == "npm_version":
                    fixture.npm["version"] = "13.0.0"
                elif change == "npm_binary":
                    fixture.npm["bin"] = {}
                elif change == "source_launcher":
                    fixture.launcher["mcpServers"]["gitlab-sw"]["args"] = ["old-runtime"]
                elif change == "archive_manifest":
                    fixture.manifest["description"] = "Changed source"
                else:
                    fixture.release["draft"] = True
                with self.assertRaises(ValueError):
                    self.refresh(fixture)
                self.assertEqual({p.relative_to(self.root): p.read_bytes()
                                  for p in self.root.rglob("*.json")}, before)

    def test_public_download_does_not_receive_api_credentials(self):
        # GitHub release downloads redirect to another origin; keep bearer headers on the API.
        client = marketplace.Client()
        with patch.dict(os.environ, {"GH_TOKEN": "synthetic-api-token"}), patch.object(
                marketplace.urllib.request, "urlopen",
                side_effect=[io.BytesIO(b"{}"), io.BytesIO(b"archive")]) as opened:
            client.json("/repos/structured-world/gitlab-mcp/releases/latest")
            destination = io.BytesIO()
            client.download("https://github.com/structured-world/gitlab-mcp/releases/download/test/archive.zip", destination)
        self.assertEqual(opened.call_args_list[0].args[0].get_header("Authorization"),
                         "Bearer synthetic-api-token")
        self.assertIsInstance(opened.call_args_list[1].args[0], str)
        self.assertEqual(destination.getvalue(), b"archive")

    def test_successful_release_is_selected_even_if_latest_is_still_publishing(self):
        # A newer incomplete release must not hide the successfully completed source release.
        fixture = ReleaseFixture()
        original = fixture.json
        def selected(path):
            self.assertFalse(path.endswith('/releases/latest'))
            return original(path)
        fixture.json = selected
        self.assertTrue(marketplace.refresh(self.root, fixture, fixture.tag))

    def test_invalid_source_tag_is_rejected_before_network_access(self):
        # Dispatch input is a tag selector, never an arbitrary API path.
        fixture = ReleaseFixture()
        with patch.object(fixture, 'json') as fetch:
            with self.assertRaises(ValueError):
                marketplace.refresh(self.root, fixture, '../../other-repository')
            fetch.assert_not_called()

    def test_refresh_preserves_catalog_order_and_install_policy(self):
        # Only the source revision changes; central curation remains at the catalog owner.
        self.refresh(ReleaseFixture())
        catalog = json.loads(self.catalog.read_text())
        catalog['plugins'][1]['policy']['installation'] = 'NOT_AVAILABLE'
        catalog['plugins'].append({'name': 'last-plugin'})
        self.catalog.write_text(json.dumps(catalog))
        updated = ReleaseFixture('13.1.0')
        updated.commit = 'b' * 40
        self.refresh(updated)
        actual = json.loads(self.catalog.read_text())
        self.assertEqual([entry['name'] for entry in actual['plugins']],
                         ['another-plugin', 'gitlab-mcp', 'last-plugin'])
        self.assertEqual(actual['plugins'][1]['policy']['installation'], 'NOT_AVAILABLE')
        self.assertEqual(actual['plugins'][1]['source']['sha'], 'b' * 40)

    def test_download_must_include_the_installable_marketplace_catalog(self):
        # A valid checksum and runtime are insufficient if extraction cannot be registered.
        fixture = ReleaseFixture()
        rewritten = io.BytesIO()
        with zipfile.ZipFile(io.BytesIO(fixture.archive)) as old, zipfile.ZipFile(rewritten, 'w') as new:
            for name in old.namelist():
                if name != '.agents/plugins/marketplace.json':
                    new.writestr(name, old.read(name))
        fixture.archive = rewritten.getvalue()
        fixture.checksum = hashlib.sha256(fixture.archive).hexdigest()
        fixture.sidecar = f'{fixture.checksum}  gitlab-mcp-codex.zip\n'.encode()
        fixture.release['assets'][0]['size'] = len(fixture.archive)
        before = self.catalog.read_bytes()
        with self.assertRaisesRegex(ValueError, 'Release archive is incomplete'):
            self.refresh(fixture)
        self.assertEqual(self.catalog.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
