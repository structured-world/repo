#!/usr/bin/env python3
"""Generate site from manifests and markdown docs.

Reads package manifests from packages/meta/*/manifest.json (CI artifacts)
or manifests/*/manifest.json (committed fallback), then generates:
  - index.html        (from templates/index.html + manifest data)
  - docs/index.html   (documentation index)
  - docs/<slug>/      (per-doc HTML pages)
  - sitemap.xml, sitemap.txt, robots.txt
"""
import json
import os
import re
import shutil
import sys
from datetime import datetime, timezone
from html import escape
from html.parser import HTMLParser
from pathlib import Path

try:
    import markdown
except (ImportError, ModuleNotFoundError) as exc:
    print("Missing dependency: markdown. Install with: python3 -m pip install markdown", file=sys.stderr)
    raise SystemExit(1) from exc

ROOT = Path(__file__).resolve().parents[1]
DOCS_DIR = ROOT / "docs"
TEMPLATES_DIR = ROOT / "templates"
SITE_BASE_URL = os.environ.get("SITE_BASE_URL", "https://repo.sw.foundation").rstrip("/")

# Allowlisted HTML tags for manifest summary fields.
_SUMMARY_ALLOWED_TAGS = frozenset({"code", "strong", "em", "b", "i"})


class _SanitizeHTML(HTMLParser):
    """Strip HTML tags not in the allowlist, preserving text content."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self._parts = []

    def handle_starttag(self, tag, attrs):
        if tag in _SUMMARY_ALLOWED_TAGS:
            self._parts.append(f"<{tag}>")

    def handle_endtag(self, tag):
        if tag in _SUMMARY_ALLOWED_TAGS:
            self._parts.append(f"</{tag}>")

    def handle_data(self, data):
        self._parts.append(escape(data))

    def get_clean(self):
        return "".join(self._parts)


def sanitize_summary(raw):
    """Sanitize manifest summary to only allow safe inline HTML tags."""
    parser = _SanitizeHTML()
    parser.feed(raw)
    return parser.get_clean()


_DANGEROUS_TAGS_RE = re.compile(
    r"<(script|iframe|object|embed|form|input|textarea|button|style|link|meta|base)"
    r"[^>]*>.*?</\1>",
    re.DOTALL | re.IGNORECASE,
)
_DANGEROUS_VOID_RE = re.compile(
    r"<(script|iframe|object|embed|form|input|textarea|button|style|link|meta|base)"
    r"[^>]*/?\s*>",
    re.IGNORECASE,
)
_EVENT_HANDLER_RE = re.compile(r"\s+on\w+\s*=\s*(?:\"[^\"]*\"|'[^']*'|\S+)", re.IGNORECASE)
_DANGEROUS_URL_RE = re.compile(
    r'(href|src|action)\s*=\s*["\']?\s*(javascript|vbscript|data)\s*:[^"\'>\s]*["\']?',
    re.IGNORECASE,
)


def sanitize_doc_html(html):
    """Strip dangerous HTML tags, event handlers, and unsafe URL schemes from rendered markdown.

    This is defense-in-depth — manifests and docs come from CI artifacts of
    repos we control, not arbitrary user input.  A full HTML sanitizer library
    (e.g. bleach) would be more robust but adds a dependency; regex coverage
    is acceptable given the controlled input source.
    """
    html = _DANGEROUS_TAGS_RE.sub("", html)
    html = _DANGEROUS_VOID_RE.sub("", html)
    html = _EVENT_HANDLER_RE.sub("", html)
    html = _DANGEROUS_URL_RE.sub(r'\1="#"', html)  # replaces entire attribute value
    return html


# ---------------------------------------------------------------------------
# SVG icons for package cards (keyed by manifest "icon" field)
# ---------------------------------------------------------------------------
ICONS = {
    "shield": '<svg width="28" height="28" viewBox="0 0 24 24" fill="white"><path d="M12 1L3 5v6c0 5.55 3.84 10.74 9 12 5.16-1.26 9-6.45 9-12V5l-9-4zm0 10.99h7c-.53 4.12-3.28 7.79-7 8.94V12H5V6.3l7-3.11v8.8z"/></svg>',
    "database": '<svg width="28" height="28" viewBox="0 0 24 24" fill="white"><path d="M20 6H16V4C16 2.9 15.1 2 14 2H10C8.9 2 8 2.9 8 4V6H4C2.9 6 2 6.9 2 8V20C2 21.1 2.9 22 4 22H20C21.1 22 22 21.1 22 20V8C22 6.9 21.1 6 20 6ZM10 4H14V6H10V4ZM12 18C10.34 18 9 16.66 9 15C9 13.34 10.34 12 12 12C13.66 12 15 13.34 15 15C15 16.66 13.66 18 12 18Z"/></svg>',
    "globe": '<svg width="28" height="28" viewBox="0 0 24 24" fill="white"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-1 17.93c-3.95-.49-7-3.85-7-7.93 0-.62.08-1.21.21-1.79L9 15v1c0 1.1.9 2 2 2v1.93zm6.9-2.54c-.26-.81-1-1.39-1.9-1.39h-1v-3c0-.55-.45-1-1-1H8v-2h2c.55 0 1-.45 1-1V7h2c1.1 0 2-.9 2-2v-.41c2.93 1.19 5 4.06 5 7.41 0 2.08-.8 3.97-2.1 5.39z"/></svg>',
}

ICONS_SMALL = {
    "shield": '<svg width="16" height="16" viewBox="0 0 24 24" fill="white"><path d="M12 1L3 5v6c0 5.55 3.84 10.74 9 12 5.16-1.26 9-6.45 9-12V5l-9-4z"/></svg>',
    "database": '<svg width="16" height="16" viewBox="0 0 24 24" fill="white"><path d="M20 6H16V4C16 2.9 15.1 2 14 2H10C8.9 2 8 2.9 8 4V6H4C2.9 6 2 6.9 2 8V20C2 21.1 2.9 22 4 22H20C21.1 22 22 21.1 22 20V8C22 6.9 21.1 6 20 6Z"/></svg>',
    "globe": '<svg width="16" height="16" viewBox="0 0 24 24" fill="white"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-1 17.93c-3.95-.49-7-3.85-7-7.93 0-.62.08-1.21.21-1.79L9 15v1c0 1.1.9 2 2 2v1.93z"/></svg>',
}

# Distro SVG icons for platform cards and install tabs
DISTRO_ICONS = {
    "fedora": '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-1 17.93c-3.95-.49-7-3.85-7-7.93 0-.62.08-1.21.21-1.79L9 15v1c0 1.1.9 2 2 2v1.93zm6.9-2.54c-.26-.81-1-1.39-1.9-1.39h-1v-3c0-.55-.45-1-1-1H8v-2h2c.55 0 1-.45 1-1V7h2c1.1 0 2-.9 2-2v-.41c2.93 1.19 5 4.06 5 7.41 0 2.08-.8 3.97-2.1 5.39z"/></svg>',
    "ubuntu": '<svg viewBox="0 0 24 24" fill="currentColor"><circle cx="12" cy="12" r="10"/></svg>',
    "debian": '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M12 2l3.09 6.26L22 9.27l-5 4.87 1.18 6.88L12 17.77l-6.18 3.25L7 14.14 2 9.27l6.91-1.01L12 2z"/></svg>',
}

COPY_BTN_SVG = '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 01-2-2V4a2 2 0 012-2h9a2 2 0 012 2v1"/></svg>'


# ---------------------------------------------------------------------------
# Load manifests
# ---------------------------------------------------------------------------
def load_manifests():
    """Load manifests from CI artifact dir or committed fallback."""
    manifests = []

    def _load_from(base_dir):
        """Try loading manifests from subdirs of *base_dir*."""
        loaded = []
        if not base_dir.is_dir():
            return loaded
        for d in sorted(base_dir.iterdir()):
            mf = d / "manifest.json"
            if not mf.is_file():
                continue
            try:
                data = json.loads(mf.read_text(encoding="utf-8"))
                data["_meta_dir"] = str(d)
                loaded.append(data)
            except (json.JSONDecodeError, OSError) as exc:
                print(f"Warning: failed to load {mf}: {exc}", file=sys.stderr)
        return loaded

    # CI artifacts: packages/meta/*/manifest.json
    manifests = _load_from(ROOT / "packages" / "meta")

    # Fallback: manifests/*/manifest.json (committed snapshot for local dev / GitHub Pages)
    if not manifests:
        manifests = _load_from(ROOT / "manifests")
    return manifests


# ---------------------------------------------------------------------------
# HTML generators for index.html placeholders
# ---------------------------------------------------------------------------
def gen_hero_subtitle(manifests):
    parts = []
    for m in manifests:
        desc = m.get("project", {}).get("description", "")
        if desc:
            parts.append(desc)
    return "\n                ".join(escape(p) for p in parts) if parts else "Signed packages for modern Linux distributions."


def gen_meta_keywords(manifests):
    keywords = ["Linux packages", "RPM", "DEB", "Ubuntu", "Fedora", "Debian"]
    for m in manifests:
        for pkg in m.get("packages", []):
            keywords.append(pkg.get("displayName", pkg["name"]))
    return escape(", ".join(keywords))


def gen_platform_cards(manifests):
    """Generate platform badge cards for the hero section."""
    # Merge versions across manifests for the same distro.
    distro_map = {}  # id -> {name, versions_set}
    distro_order = []
    for m in manifests:
        platforms = m.get("platforms", {})
        for ptype in ("rpm", "deb"):
            for distro in platforms.get(ptype, {}).get("distros", []):
                did = distro["id"]
                versions = distro.get("versions", distro.get("codenames", []))
                if did not in distro_map:
                    distro_map[did] = {"name": distro["name"], "versions": list(versions)}
                    distro_order.append(did)
                else:
                    existing = distro_map[did]["versions"]
                    for v in versions:
                        if v not in existing:
                            existing.append(v)

    cards = []
    for did in distro_order:
        info = distro_map[did]
        icon = DISTRO_ICONS.get(did, DISTRO_ICONS["fedora"])
        name = escape(info["name"])
        ver_str = escape(", ".join(info["versions"]))
        cards.append(
            f'<div class="platform-card">\n'
            f"                    {icon}\n"
            f'                    <div class="platform-info">\n'
            f"                        <h4>{name}</h4>\n"
            f"                        <span>{ver_str}</span>\n"
            f"                    </div>\n"
            f"                </div>"
        )
    return "\n                ".join(cards)


def _pkg_slug(name, project_id=""):
    """Derive a short slug for HTML element IDs (e.g. 'strongswan-sw' -> 'sw').

    Short slugs are preferred for readability, but if two packages from
    different projects would collide, callers fall back to the full name.
    """
    prefix = f"{project_id}-" if project_id else ""
    if prefix and name.startswith(prefix):
        return name[len(prefix):]
    return name


def gen_package_cards(manifests, slug_mapping):
    """Generate package card HTML for the packages grid.

    Note: packages may carry a ``docs`` field linking to a doc slug.
    This is not yet wired into the card HTML but is part of the manifest
    schema for future per-package documentation links.
    """
    cards = []
    for m in manifests:
        proj = m.get("project", {})
        license_id = escape(proj.get("license", ""))
        for pkg in m.get("packages", []):
            cat = escape(pkg.get("category", "main"))
            icon = ICONS.get(pkg.get("icon", "shield"), ICONS["shield"])
            display = escape(pkg["displayName"])
            name = escape(pkg["name"])
            summary = sanitize_summary(pkg.get("summary", ""))
            slug = slug_mapping.get(pkg["name"], pkg["name"])

            cards.append(
                f'<div class="package-card {cat}">\n'
                f'                    <div class="package-icon">\n'
                f"                        {icon}\n"
                f"                    </div>\n"
                f"                    <h3>{display}</h3>\n"
                f'                    <code class="pkg-name">{name}</code>\n'
                f'                    <p class="pkg-desc">\n'
                f"                        {summary}\n"
                f"                    </p>\n"
                f'                    <div class="package-meta">\n'
                f'                        <span class="meta-badge">\n'
                f'                            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/></svg>\n'
                f"                            {license_id}\n"
                f"                        </span>\n"
                f'                        <span class="meta-badge">\n'
                f'                            Version: <span class="version" id="version-{escape(slug)}">loading...</span>\n'
                f"                        </span>\n"
                f'                        <span class="meta-badge" id="size-{escape(slug)}-badge" style="display:none">\n'
                f'                            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M21 15v4a2 2 0 01-2 2H5a2 2 0 01-2-2v-4M7 10l5 5 5-5M12 15V3"/></svg>\n'
                f'                            <span id="size-{escape(slug)}"></span>\n'
                f"                        </span>\n"
                f"                    </div>\n"
                f"                </div>"
            )
    return "\n\n                ".join(cards)


def _code_block(lang, code_html, with_copy=True):
    """Wrap code in a styled code block."""
    copy = ""
    if with_copy:
        copy = (
            f'<button class="code-copy" onclick="copyCode(this)">\n'
            f"                                        {COPY_BTN_SVG}\n"
            f"                                        Copy\n"
            f"                                    </button>"
        )
    return (
        f'<div class="code-block">\n'
        f'                                <div class="code-header">\n'
        f'                                    <span class="code-lang">{escape(lang)}</span>\n'
        f"                                    {copy}\n"
        f"                                </div>\n"
        f"                                <pre><code>{code_html}</code></pre>\n"
        f"                            </div>"
    )


def _install_card(pkg, category, icon_key, version_badges, supported_text, install_lines):
    """Generate a single install card."""
    icon = ICONS_SMALL.get(icon_key, ICONS_SMALL["shield"])
    display = escape(pkg["displayName"])
    badges = "\n                                ".join(
        f'<span class="version-badge">{escape(b)}</span>' for b in version_badges
    )
    code_html = install_lines
    code = _code_block("bash", code_html)

    return (
        f'<div class="install-card {escape(category)}">\n'
        f'                        <div class="install-card-header">\n'
        f'                            <div class="install-card-title">\n'
        f'                                <div class="icon">\n'
        f"                                    {icon}\n"
        f"                                </div>\n"
        f"                                <h4>{display}</h4>\n"
        f"                            </div>\n"
        f'                            <div class="install-card-versions">\n'
        f"                                {badges}\n"
        f"                            </div>\n"
        f"                        </div>\n"
        f'                        <div class="install-card-body">\n'
        f'                            <p class="supported">{escape(supported_text)}</p>\n'
        f"                            {code}\n"
        f"                        </div>\n"
        f"                    </div>"
    )


def gen_install_tabs(manifests):
    """Generate the full install tabs section (RPM + DEB)."""
    # Collect packages per format — a package only appears in the RPM tab if
    # its manifest declares platforms.rpm, and likewise for DEB.  This avoids
    # showing incorrect install instructions for projects that publish only
    # one package format.
    rpm_packages = []
    deb_packages = []
    rpm_info = {}
    deb_info = {}
    for m in manifests:
        platforms = m.get("platforms", {})
        pkgs = m.get("packages", [])
        if "rpm" in platforms:
            rpm_packages.extend(pkgs)
        if "deb" in platforms:
            deb_packages.extend(pkgs)

        if "rpm" in platforms:
            if not rpm_info:
                rpm_info = dict(platforms["rpm"])
                rpm_info["distros"] = list(platforms["rpm"].get("distros", []))
            else:
                # Merge distros from additional manifests.
                existing_ids = {d["id"] for d in rpm_info["distros"]}
                for d in platforms["rpm"].get("distros", []):
                    if d["id"] not in existing_ids:
                        rpm_info["distros"].append(d)
                        existing_ids.add(d["id"])
        if "deb" in platforms:
            if not deb_info:
                deb_info = dict(platforms["deb"])
                deb_info["distros"] = list(platforms["deb"].get("distros", []))
            else:
                existing_ids = {d["id"] for d in deb_info["distros"]}
                for d in platforms["deb"].get("distros", []):
                    if d["id"] not in existing_ids:
                        deb_info["distros"].append(d)
                        existing_ids.add(d["id"])

    if not rpm_packages and not deb_packages:
        return ""

    parts = []

    # Tab buttons — tabs represent package format (RPM vs DEB), not individual distros.
    # All RPM distros share one tab, all DEB distros share another.
    # IDs use "fedora"/"debian" to match the JS switchDistro() in the template;
    # these are intentionally hardcoded for the current distro set.  When a
    # non-Fedora RPM distro or non-Debian/Ubuntu DEB distro is added, the IDs,
    # labels, and icons here should be generalized (along with switchDistro()).
    tabs = []
    first_tab = None
    if rpm_info:
        first_tab = first_tab or "fedora"
        tabs.append(
            f'<button class="distro-tab{" active" if first_tab == "fedora" else ""}" onclick="switchDistro(\'fedora\')">\n'
            f"                    {DISTRO_ICONS.get('fedora', '')}\n"
            f"                    Fedora (RPM)\n"
            f"                </button>"
        )
    if deb_info:
        first_tab = first_tab or "debian"
        tabs.append(
            f'<button class="distro-tab{" active" if first_tab == "debian" else ""}" onclick="switchDistro(\'debian\')">\n'
            f"                    {DISTRO_ICONS.get('ubuntu', '')}\n"
            f"                    Ubuntu / Debian (DEB)\n"
            f"                </button>"
        )

    if tabs:
        parts.append(f'<div class="distro-tabs">\n                {"".join(tabs)}\n            </div>')

    # RPM content
    if rpm_info:
        rpm_cards = []
        distros = rpm_info.get("distros", [])
        all_versions = []
        for d in distros:
            prefix = d.get("prefix", "fc")
            for v in d.get("versions", []):
                all_versions.append(f"{prefix}{v}")
        supported_all = ", ".join(f'{d["name"]} {", ".join(d.get("versions", []))}' for d in distros)
        arch = distros[0].get("arch", "x86_64") if distros else "x86_64"
        supported_all += f" ({arch})" if supported_all else ""
        install_cmd = rpm_info.get("installCmd", "sudo dnf install")
        repo_setup = rpm_info.get("repoSetup", "")

        # Repo setup is shown only on the primary package card (no `requires`).
        # Plugin cards omit it because the user must install the base package first,
        # which already includes the repo setup instructions.
        for pkg in rpm_packages:
            cat = pkg.get("category", "main")
            req = pkg.get("requires")
            if req:
                sup_text = f"Requires {req}"
                code_html = (
                    f'<span class="comment"># Install {escape(pkg["displayName"])}</span>\n'
                    f'{escape(install_cmd)} <span class="cmd">{escape(pkg["name"])}</span>'
                )
            else:
                sup_text = supported_all
                code_html = (
                    f'<span class="comment"># Add repository</span>\n'
                    f"{escape(repo_setup)}\n\n"
                    f'<span class="comment"># Install {escape(pkg["displayName"])}</span>\n'
                    f'{escape(install_cmd)} <span class="cmd">{escape(pkg["name"])}</span>'
                )
            rpm_cards.append(_install_card(pkg, cat, pkg.get("icon", "shield"), all_versions, sup_text, code_html))

        active = " active" if first_tab == "fedora" else ""
        rpm_grid = "\n\n                    ".join(rpm_cards)
        parts.append(
            f'<div id="distro-fedora" class="distro-content{active}">\n'
            f'                <div class="install-grid">\n'
            f"                    {rpm_grid}\n"
            f"                </div>\n"
            f"            </div>"
        )

    # DEB content
    if deb_info:
        deb_cards = []
        distros = deb_info.get("distros", [])
        all_codenames = []
        for d in distros:
            all_codenames.extend(d.get("codenames", []))
        supported_parts = []
        for d in distros:
            names = [f'{d["name"]} {v}' for v in d.get("versions", [])]
            supported_parts.append(" | ".join(names) if names else d["name"])
        supported_all = " | ".join(supported_parts)
        install_cmd = deb_info.get("installCmd", "sudo apt install")
        repo_setup = deb_info.get("repoSetup", "")

        # Same repo-setup logic as RPM — see comment above.
        for pkg in deb_packages:
            cat = pkg.get("category", "main")
            req = pkg.get("requires")
            if req:
                sup_text = f"Requires {req}"
                code_html = (
                    f'<span class="comment"># Install {escape(pkg["displayName"])}</span>\n'
                    f'{escape(install_cmd)} <span class="cmd">{escape(pkg["name"])}</span>'
                )
            else:
                sup_text = supported_all
                code_html = (
                    f"{escape(repo_setup)}\n\n"
                    f'<span class="comment"># Install {escape(pkg["displayName"])}</span>\n'
                    f'{escape(install_cmd)} <span class="cmd">{escape(pkg["name"])}</span>'
                )
            deb_cards.append(_install_card(pkg, cat, pkg.get("icon", "shield"), all_codenames, sup_text, code_html))

        active = " active" if first_tab == "debian" else ""
        deb_grid = "\n\n                    ".join(deb_cards)
        parts.append(
            f'<div id="distro-debian" class="distro-content{active}">\n'
            f'                <div class="install-grid">\n'
            f"                    {deb_grid}\n"
            f"                </div>\n"
            f"            </div>"
        )

    return "\n\n            ".join(parts)


def gen_docs_callout(all_docs):
    """Generate callout linking to docs if any exist."""
    if not all_docs:
        return ""
    return (
        '<div class="callout">\n'
        '                <div class="callout-icon">&#128218;</div>\n'
        "                <div>\n"
        '                    <h4 class="callout-title">Documentation</h4>\n'
        '                    <p class="callout-text">\n'
        '                        See our <a href="/docs/">documentation</a> for setup guides and configuration.\n'
        "                    </p>\n"
        "                </div>\n"
        "            </div>"
    )


def gen_footer_projects(manifests):
    """Generate footer sections for each project."""
    sections = []
    for m in manifests:
        proj = m.get("project", {})
        name = escape(proj.get("name", ""))
        links = []
        if proj.get("homepage"):
            links.append(f'<li><a href="{escape(proj["homepage"])}">{name}</a></li>')
        if proj.get("issueTracker"):
            links.append(f'<li><a href="{escape(proj["issueTracker"])}">Issue Tracker</a></li>')
        if proj.get("releases"):
            links.append(f'<li><a href="{escape(proj["releases"])}">Releases</a></li>')
        if proj.get("upstream"):
            links.append(f'<li><a href="{escape(proj["upstream"])}">Upstream</a></li>')
        if links:
            items = "\n                        ".join(links)
            sections.append(
                f'<div class="footer-section">\n'
                f"                    <h4>{name}</h4>\n"
                f"                    <ul>\n"
                f"                        {items}\n"
                f"                    </ul>\n"
                f"                </div>"
            )
    return "\n                ".join(sections)


def gen_footer_legal(manifests):
    """Generate legal/trademark notices from all manifests."""
    lines = []
    for m in manifests:
        proj = m.get("project", {})
        lic = proj.get("license", "")
        if lic:
            lines.append(f"<p><strong>License ({escape(proj.get('name', ''))}):</strong> {escape(lic)}</p>")
        tm = proj.get("trademarkNotice", "")
        if tm:
            lines.append(f"<p><strong>Trademark Notice:</strong> {escape(tm)}</p>")
        src = proj.get("sourceNotice", "")
        if src:
            hp = proj.get("homepage", "")
            if hp:
                lines.append(f'<p><strong>Source Availability:</strong> {escape(src)} (<a href="{escape(hp)}">{escape(hp.replace("https://", ""))}</a>)</p>')
            else:
                lines.append(f"<p><strong>Source Availability:</strong> {escape(src)}</p>")
    return "\n                    ".join(lines)


def _safe_inline_json(obj):
    """Serialize to JSON safe for embedding in HTML <script> tags."""
    # Escape sequences that could break out of inline script context.
    return json.dumps(obj).replace("</", r"<\/")


def build_slug_mapping(manifests):
    """Build a global package-name → slug mapping, detecting collisions."""
    mapping = {}
    slug_to_name = {}
    for m in manifests:
        project_id = m.get("project", {}).get("id", "")
        for pkg in m.get("packages", []):
            name = pkg["name"]
            slug = _pkg_slug(name, project_id)
            if slug in slug_to_name and slug_to_name[slug] != name:
                # Collision: fall back to full package name for both.
                prev_name = slug_to_name[slug]
                mapping[prev_name] = prev_name
                slug = name
            slug_to_name[slug] = name
            mapping[name] = slug
    return mapping


def gen_package_js_data(slug_mapping):
    """Generate JSON object mapping package name → HTML slug for JS version loader."""
    return _safe_inline_json(slug_mapping)


def gen_deb_sources(manifests):
    """Generate JSON array of DEB Packages file paths for JS version loader."""
    codenames = []
    seen = set()
    for m in manifests:
        for d in m.get("platforms", {}).get("deb", {}).get("distros", []):
            for cn in d.get("codenames", []):
                if cn not in seen:
                    codenames.append(cn)
                    seen.add(cn)
    paths = [f"deb/dists/{cn}/main/binary-amd64/Packages" for cn in codenames]
    return _safe_inline_json(paths)


# ---------------------------------------------------------------------------
# Generate index.html
# ---------------------------------------------------------------------------
def generate_index(manifests, all_docs):
    tmpl_path = TEMPLATES_DIR / "index.html"
    if not tmpl_path.exists():
        print(f"Template not found: {tmpl_path}", file=sys.stderr)
        raise SystemExit(1)

    html = tmpl_path.read_text(encoding="utf-8")

    slug_mapping = build_slug_mapping(manifests)

    replacements = {
        "{{SITE_URL}}": escape(SITE_BASE_URL),
        "{{META_KEYWORDS}}": gen_meta_keywords(manifests),
        "{{HERO_SUBTITLE}}": gen_hero_subtitle(manifests),
        "{{PLATFORM_CARDS}}": gen_platform_cards(manifests),
        "{{PACKAGE_CARDS}}": gen_package_cards(manifests, slug_mapping),
        "{{INSTALL_TABS}}": gen_install_tabs(manifests),
        "{{DOCS_CALLOUT}}": gen_docs_callout(all_docs),
        "{{FOOTER_PROJECTS}}": gen_footer_projects(manifests),
        "{{FOOTER_LEGAL}}": gen_footer_legal(manifests),
        "{{PACKAGE_JS_DATA}}": gen_package_js_data(slug_mapping),
        "{{DEB_SOURCES}}": gen_deb_sources(manifests),
    }

    for marker, value in replacements.items():
        html = html.replace(marker, value)

    leftover = re.findall(r"\{\{[A-Z_]+\}\}", html)
    if leftover:
        print(f"Error: unresolved placeholders in index.html: {leftover}", file=sys.stderr)
        raise SystemExit(1)

    (ROOT / "index.html").write_text(html, encoding="utf-8")
    print("Generated index.html")


# ---------------------------------------------------------------------------
# Generate doc pages
# ---------------------------------------------------------------------------
def generate_docs(manifests):
    """Process markdown docs from manifests and return page metadata list."""
    doc_template_path = DOCS_DIR / "_template.html"
    if not doc_template_path.exists():
        print(f"Doc template not found: {doc_template_path}", file=sys.stderr)
        raise SystemExit(1)

    doc_template = doc_template_path.read_text(encoding="utf-8")
    pages = []
    seen_slugs = {}  # slug -> project id, detect cross-project collisions

    for m in manifests:
        meta_dir = Path(m.get("_meta_dir", ""))
        docs_dir = meta_dir / "docs"

        for doc_entry in m.get("docs", []):
            slug = doc_entry["slug"]
            if not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]*[a-z0-9])?", slug):
                print(
                    f"Error: invalid doc slug '{slug}' "
                    f"(must use lowercase letters, digits, and hyphens, and start/end with a letter or digit)",
                    file=sys.stderr,
                )
                raise SystemExit(1)
            project_id = m.get("project", {}).get("id", "?")
            if slug in seen_slugs and seen_slugs[slug] != project_id:
                print(f"Error: doc slug '{slug}' used by both '{seen_slugs[slug]}' and '{project_id}'", file=sys.stderr)
                raise SystemExit(1)
            seen_slugs[slug] = project_id
            title_override = doc_entry.get("title", "")
            md_file = doc_entry.get("file", f"{slug}.md")
            if "/" in md_file or "\\" in md_file or md_file.startswith("."):
                print(f"Error: invalid doc file path '{md_file}' (no path separators or leading dots)", file=sys.stderr)
                raise SystemExit(1)
            md_path = docs_dir / md_file

            if not md_path.exists():
                # Fall back to docs/ dir in repo root (legacy).
                md_path = DOCS_DIR / f"{slug}.md"
            if not md_path.exists():
                print(f"Warning: doc file not found: {md_path} (slug: {slug})", file=sys.stderr)
                continue

            try:
                md = markdown.Markdown(extensions=["extra", "toc"])
                raw = md_path.read_text(encoding="utf-8")
                html_body = sanitize_doc_html(md.convert(raw))
                # Prefer manifest title when provided; otherwise derive from
                # the first markdown heading, or fall back to the slug.
                if title_override:
                    title = title_override
                elif isinstance(md.toc_tokens, list) and md.toc_tokens:
                    title = md.toc_tokens[0].get("name", "") or slug.replace("-", " ").title()
                else:
                    title = slug.replace("-", " ").title()
                description = f"{title} documentation for SW Foundation."
            except Exception as exc:
                print(f"Error: failed to render {md_path.name}: {exc}", file=sys.stderr)
                raise SystemExit(1) from exc

            out_dir = DOCS_DIR / slug
            out_dir.mkdir(parents=True, exist_ok=True)
            out_path = out_dir / "index.html"
            canonical = f"{SITE_BASE_URL}/docs/{slug}/"

            page_html = doc_template
            # Only check title/description/canonical for template markers (not html_body,
            # which may legitimately contain {{ in code samples or templating docs).
            for value in (title, description, canonical):
                if "{{" in value or "}}" in value:
                    raise SystemExit(f"Template marker found in replacement value from {md_path.name}")
            page_html = page_html.replace("{{TITLE}}", escape(title))
            page_html = page_html.replace("{{DESCRIPTION}}", escape(description))
            page_html = page_html.replace("{{CANONICAL}}", escape(canonical))
            page_html = page_html.replace("{{CONTENT}}", html_body)

            out_path.write_text(page_html, encoding="utf-8")

            lastmod_dt = datetime.fromtimestamp(md_path.stat().st_mtime, tz=timezone.utc)
            pages.append({
                "title": title,
                "url": f"/docs/{slug}/",
                "canonical": canonical,
                "lastmod": lastmod_dt.strftime("%Y-%m-%d"),
                "lastmod_dt": lastmod_dt,
            })

    # Remove stale doc directories that are no longer in any manifest.
    # This prevents previously published docs from lingering after removal/rename.
    current_slugs = set(seen_slugs.keys())
    if DOCS_DIR.is_dir():
        for child in DOCS_DIR.iterdir():
            if child.is_dir() and child.name not in current_slugs:
                shutil.rmtree(child)

    return pages


def generate_docs_index(pages, doc_template_path):
    """Generate docs/index.html listing all documentation pages.

    Always generates a page because the site nav statically links to /docs/.
    When no docs exist, a placeholder page is written instead of a listing.
    """
    doc_template = doc_template_path.read_text(encoding="utf-8")
    if pages:
        items = "\n".join([
            f'<li><a href="{escape(p["url"])}">{escape(p["title"])}</a></li>' for p in pages
        ])
        content = f'<h1>Documentation</h1><p>Guides for SW Foundation packages.</p><ul>{items}</ul>'
    else:
        content = '<h1>Documentation</h1><p>No documentation available yet.</p>'
    index_html = doc_template
    index_html = index_html.replace("{{TITLE}}", "Documentation")
    index_html = index_html.replace("{{DESCRIPTION}}", "SW Foundation documentation index.")
    index_html = index_html.replace("{{CANONICAL}}", f"{SITE_BASE_URL}/docs/")
    index_html = index_html.replace("{{CONTENT}}", content)
    (DOCS_DIR / "index.html").write_text(index_html, encoding="utf-8")


# ---------------------------------------------------------------------------
# Sitemap & robots
# ---------------------------------------------------------------------------
def generate_sitemap(pages):
    urls = []
    txt_urls = []
    if pages:
        latest_dt = max(p["lastmod_dt"] for p in pages)
        latest = latest_dt.strftime("%Y-%m-%d")
        root_url = f"{SITE_BASE_URL}/"
        docs_url = f"{SITE_BASE_URL}/docs/"
        urls.extend([
            f"  <url><loc>{escape(root_url)}</loc><lastmod>{latest}</lastmod></url>",
            f"  <url><loc>{escape(docs_url)}</loc><lastmod>{latest}</lastmod></url>",
        ])
        txt_urls.extend([root_url, docs_url])
        for p in pages:
            urls.append(f'  <url><loc>{escape(p["canonical"])}</loc><lastmod>{p["lastmod"]}</lastmod></url>')
            txt_urls.append(p["canonical"])
    else:
        today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        root_url = f"{SITE_BASE_URL}/"
        urls.append(f"  <url><loc>{escape(root_url)}</loc><lastmod>{today}</lastmod></url>")
        txt_urls.append(root_url)

    sitemap_lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
        *urls,
        "</urlset>",
    ]
    (ROOT / "sitemap.xml").write_text("\n".join(sitemap_lines) + "\n", encoding="utf-8")
    if txt_urls:
        (ROOT / "sitemap.txt").write_text("\n".join(txt_urls) + "\n", encoding="utf-8")

    robots = f"User-agent: *\nAllow: /\nSitemap: {SITE_BASE_URL}/sitemap.xml\n"
    (ROOT / "robots.txt").write_text(robots, encoding="utf-8")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    manifests = load_manifests()
    if not manifests:
        print("Warning: no manifests found; generating minimal site", file=sys.stderr)

    pages = generate_docs(manifests)
    generate_index(manifests, pages)
    generate_docs_index(pages, DOCS_DIR / "_template.html")
    generate_sitemap(pages)

    print(f"Generated {len(pages)} docs pages, index.html, docs/index.html, sitemap.xml, robots.txt")


if __name__ == "__main__":
    main()
