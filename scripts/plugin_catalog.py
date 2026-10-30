"""Render the shared plugin catalog without changing package publication outputs."""
import json
from html import escape
import re
from urllib.parse import quote, urlencode, urlsplit
import xml.etree.ElementTree as ET

NAMESPACE = "http://www.sitemaps.org/schemas/sitemap/0.9"


def https(value):
    """Plugin metadata crosses into public HTML; accept HTTPS links without credentials."""
    parts = urlsplit(value)
    if parts.scheme != "https" or not parts.hostname or parts.username is not None:
        raise ValueError("Plugin listing links must use HTTPS without credentials")
    return escape(value, quote=True)


def read_catalog(root):
    catalog = json.loads((root / ".agents/plugins/marketplace.json").read_text())
    if not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", catalog["name"]):
        raise ValueError("Invalid marketplace name")
    rows = []
    seen = set()
    for entry in catalog["plugins"]:
        name = entry["name"]
        if not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", name) or name in seen:
            raise ValueError("Invalid or duplicate plugin name")
        seen.add(name)
        snapshot = json.loads((root / f"manifests/plugins/{name}.json").read_text())
        source = entry["source"]
        manifest = snapshot["manifest"]
        if (source["source"] != "git-subdir" or not re.fullmatch(r"[0-9a-f]{40}", source["sha"])
                or snapshot["commit"] != source["sha"] or manifest["name"] != name):
            raise ValueError("Plugin listing and immutable catalog source disagree")
        rows.append((entry, snapshot))
    return catalog, rows


def cards(catalog, rows):
    output = []
    for entry, snapshot in rows:
        manifest = snapshot["manifest"]
        interface = manifest["extensions"]["com.openai"]["interface"]
        name = quote(entry["name"], safe="")
        install = f"codex://plugins/install/{name}?{urlencode({'marketplace': catalog['name']})}"
        policy = entry['policy']['installation']
        if policy == 'NOT_AVAILABLE':
            action = '<span class="button unavailable" aria-disabled="true">Not available for installation</span>'
        elif policy in ('AVAILABLE', 'INSTALLED_BY_DEFAULT'):
            action = f'<a class="button primary" href="{escape(install, quote=True)}">Install in Codex <span aria-hidden="true">↗</span></a>'
        else:
            raise ValueError('Unknown catalog installation policy')
        output.append(f'''<article class="plugin-card">
  <div class="card-meta"><span class="tag">Codex desktop</span><span class="version">v{escape(manifest['version'])}</span></div>
  <h2>{escape(interface['displayName'])}</h2>
  <p>{escape(interface['shortDescription'])}</p>
  <dl><div><dt>Host</dt><dd>Codex desktop</dd></div><div><dt>Runtime</dt><dd>Node.js {escape(snapshot['runtime']['node'])}</dd></div></dl>
  {action}
  <p class="install-note">Add the marketplace below before using this button.</p>
  <div class="card-links"><a href="{https(snapshot['download'])}">Standalone ZIP</a><a href="{https(snapshot['checksum'])}">SHA-256</a><a href="{https(snapshot['release'])}">Release notes</a></div>
  <details><summary>Verified source</summary><p>Source is pinned to <code>{escape(snapshot['commit'])}</code>.</p><p>ZIP SHA-256: <code>{escape(snapshot['sha256'])}</code></p></details>
</article>''')
    if not output:
        return '<div class="empty-state"><h2>Releases are on their way</h2><p>Only verified, published plugins appear here. You can add the marketplace now; refresh it after the first plugin release.</p></div>'
    return "\n".join(output)


def sitemap_outputs(root, url):
    """Replace only this page's entry; preserve package and documentation metadata."""
    ET.register_namespace("", NAMESPACE)
    sitemap = ET.parse(root / "sitemap.xml")
    document = sitemap.getroot()
    for node in list(document):
        if node.findtext(f"{{{NAMESPACE}}}loc") == url:
            document.remove(node)
    node = ET.SubElement(document, f"{{{NAMESPACE}}}url")
    ET.SubElement(node, f"{{{NAMESPACE}}}loc").text = url
    ET.indent(sitemap, space="  ")
    xml = ET.tostring(document, encoding="unicode", xml_declaration=True) + "\n"
    previous = (root / "sitemap.txt").read_text().splitlines()
    text = "\n".join([line for line in previous if line != url] + [url]) + "\n"
    return xml, text


def generate(root, site_base):
    """Both normal site builds and plugin-only publication use the same renderer."""
    catalog, rows = read_catalog(root)
    canonical = site_base.rstrip("/") + "/plugins/"
    template = (root / "templates/plugins.html").read_text()
    html = template.replace("{{CANONICAL}}", https(canonical))
    html = html.replace("{{MARKETPLACE_NAME}}", escape(catalog["interface"]["displayName"]))
    html = html.replace("{{PLUGIN_COUNT}}", str(len(rows)))
    html = html.replace("{{PLUGIN_CARDS}}", cards(catalog, rows))
    # Package publication supplies live platform metadata. Refresh only the shared
    # navigation here, without rebuilding its page from older local manifests.
    home = (root / "index.html").read_text()
    home_template = (root / "templates/index.html").read_text()
    for value in (home, home_template):
        if value.count("<nav>") != 1 or value.count("</nav>") != 1:
            raise ValueError("Expected one shared navigation in the package homepage")
    navigation = home_template[home_template.index("<nav>"):home_template.index("</nav>") + len("</nav>")]
    home = home[:home.index("<nav>")] + navigation + home[home.index("</nav>") + len("</nav>"):]
    sitemap, sitemap_text = sitemap_outputs(root, canonical)
    outputs = {root / "plugins/index.html": html, root / "index.html": home,
               root / "sitemap.xml": sitemap, root / "sitemap.txt": sitemap_text}
    for path, value in outputs.items():
        if not path.exists() or path.read_text() != value:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(value, encoding="utf-8")
    print(f"Generated plugins/index.html ({len(rows)} released plugins)")
