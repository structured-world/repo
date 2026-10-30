#!/usr/bin/env python3
"""The rendered catalog preserves release identity and unrelated published outputs."""
import json
from pathlib import Path
import shutil
import tempfile
import unittest
import xml.etree.ElementTree as ET
from plugin_catalog import generate, NAMESPACE

ROOT = Path(__file__).resolve().parents[1]


class CatalogTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / "templates").mkdir()
        shutil.copyfile(ROOT / "templates/plugins.html", self.root / "templates/plugins.html")
        (self.root / "templates/index.html").write_text('<nav><a href="/plugins/">Plugins</a></nav>')
        (self.root / "index.html").write_text('<nav>Old menu</nav><main>Published platform metadata</main>')
        (self.root / ".agents/plugins").mkdir(parents=True)
        self.catalog = {"name": "sw-foundation", "interface": {"displayName": "sw.foundation"}, "plugins": []}
        self.catalog_path = self.root / ".agents/plugins/marketplace.json"
        self.catalog_path.write_text(json.dumps(self.catalog))
        self.root.joinpath("sitemap.xml").write_text(
            f'<urlset xmlns="{NAMESPACE}"><url><loc>https://repo.sw.foundation/docs/setup/</loc>'
            '<lastmod>2025-01-02</lastmod></url></urlset>')
        self.root.joinpath("sitemap.txt").write_text("https://repo.sw.foundation/docs/setup/\n")
        self.unrelated = {"deb/pool/package.deb": b"package",
                          "docs/setup/index.html": b"published documentation"}
        for name, value in self.unrelated.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(value)

    def add_plugin(self, display="GitLab", description="Projects and CI"):
        self.catalog["plugins"].append({"name": "gitlab-mcp", "policy": {"installation": "AVAILABLE"}, "source": {
            "source": "git-subdir", "sha": "a" * 40,
            "url": "https://github.com/structured-world/gitlab-mcp.git", "path": "./plugins/gitlab-mcp"}})
        self.catalog_path.write_text(json.dumps(self.catalog))
        self.snapshot_path = self.root / "manifests/plugins/gitlab-mcp.json"
        self.snapshot_path.parent.mkdir(parents=True)
        self.snapshot = {"source": dict(self.catalog['plugins'][0]['source']), "release": "https://github.com/structured-world/gitlab-mcp/releases/tag/test",
                         "download": "https://github.com/structured-world/gitlab-mcp/releases/download/test/bundle.zip",
                         "checksum": "https://github.com/structured-world/gitlab-mcp/releases/download/test/bundle.zip.sha256",
                         "sha256": "0" * 64, "runtime": {"node": ">=24"},
                         "manifest": {"name": "gitlab-mcp", "version": "13.0.0", "extensions": {"com.openai": {
                             "interface": {"displayName": display, "shortDescription": description}}}}}
        self.snapshot_path.write_text(json.dumps(self.snapshot))

    def test_empty_catalog_does_not_advertise_an_unreleased_plugin(self):
        # Before the first release, registration is usable without a false install button.
        generate(self.root, "https://repo.sw.foundation")
        html = self.root.joinpath("plugins/index.html").read_text()
        self.assertIn("0 released", html)
        self.assertNotIn("codex://plugins/install/", html)
        self.assertIn("codex plugin marketplace add structured-world/repo --sparse .agents/plugins", html)

    def test_rendered_release_matches_catalog_and_preserves_other_pages(self):
        # Plugin-only publishing must not regenerate or downgrade Linux package documentation.
        self.add_plugin()
        generate(self.root, "https://repo.sw.foundation")
        html = self.root.joinpath("plugins/index.html").read_text()
        self.assertIn("codex://plugins/install/gitlab-mcp?marketplace=sw-foundation", html)
        self.assertIn("v13.0.0", html)
        self.assertIn(self.snapshot["source"]["sha"], html)
        self.assertIn(self.snapshot["download"], html)
        for name, value in self.unrelated.items():
            self.assertEqual((self.root / name).read_bytes(), value)
        self.assertEqual(self.root.joinpath("index.html").read_text(),
                         '<nav><a href="/plugins/">Plugins</a></nav><main>Published platform metadata</main>')
        xml = ET.parse(self.root / "sitemap.xml")
        entries = xml.findall(f"{{{NAMESPACE}}}url")
        self.assertEqual(entries[0].findtext(f"{{{NAMESPACE}}}lastmod"), "2025-01-02")
        self.assertEqual([entry.findtext(f"{{{NAMESPACE}}}loc") for entry in entries], [
            "https://repo.sw.foundation/docs/setup/", "https://repo.sw.foundation/plugins/"])
        before = {path: path.read_bytes() for path in self.root.rglob("*") if path.is_file()}
        generate(self.root, "https://repo.sw.foundation")
        self.assertEqual({path: path.read_bytes() for path in before}, before)

    def test_metadata_cannot_inject_markup_or_script_urls(self):
        # A publisher's descriptive text crosses into HTML, not executable markup.
        self.add_plugin('<img src=x onerror="alert(1)">', "<script>bad()</script>")
        generate(self.root, "https://repo.sw.foundation")
        html = self.root.joinpath("plugins/index.html").read_text()
        self.assertIn("&lt;script&gt;bad()&lt;/script&gt;", html)
        self.assertNotIn('<img src=x', html)
        self.snapshot["download"] = "javascript:alert(1)"
        self.snapshot_path.write_text(json.dumps(self.snapshot))
        with self.assertRaises(ValueError):
            generate(self.root, "https://repo.sw.foundation")

    def test_snapshot_must_belong_to_the_selected_commit(self):
        # A stale listing must not show another version beside the selected installer.
        self.add_plugin()
        self.snapshot["source"]["sha"] = "b" * 40
        self.snapshot_path.write_text(json.dumps(self.snapshot))
        with self.assertRaises(ValueError):
            generate(self.root, "https://repo.sw.foundation")

    def test_snapshot_must_match_the_repository_and_subdirectory(self):
        # An unchanged SHA cannot bind a listing to a different repository or plugin path.
        self.add_plugin()
        original = dict(self.catalog['plugins'][0]['source'])
        for field, value in [('url', 'https://github.com/example/other.git'),
                             ('path', './plugins/other')]:
            with self.subTest(field=field):
                self.catalog['plugins'][0]['source'] = {**original, field: value}
                self.catalog_path.write_text(json.dumps(self.catalog))
                with self.assertRaisesRegex(ValueError, 'source'):
                    generate(self.root, 'https://repo.sw.foundation')

    def test_catalog_install_policy_is_reflected_in_the_page(self):
        # Source releases cannot re-enable installation disabled by the catalog owner.
        self.add_plugin()
        self.catalog['plugins'][0]['policy']['installation'] = 'NOT_AVAILABLE'
        self.catalog_path.write_text(json.dumps(self.catalog))
        generate(self.root, 'https://repo.sw.foundation')
        html = self.root.joinpath('plugins/index.html').read_text()
        self.assertNotIn('codex://plugins/install/gitlab-mcp', html)
        self.assertIn('Not available for installation', html)


if __name__ == "__main__":
    unittest.main()
