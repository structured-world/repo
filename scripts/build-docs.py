#!/usr/bin/env python3
import os
import sys
from pathlib import Path
from datetime import datetime, timezone
from html import escape

try:
    import markdown
except Exception as exc:
    print("Missing dependency: python-markdown. Install with: python3 -m pip install markdown", file=sys.stderr)
    raise SystemExit(1) from exc

ROOT = Path(__file__).resolve().parents[1]
DOCS_DIR = ROOT / "docs"
TEMPLATE_PATH = DOCS_DIR / "_template.html"
SITE_BASE_URL = os.environ.get("SITE_BASE_URL", "https://repo.sw.foundation").rstrip("/")

if not TEMPLATE_PATH.exists():
    print(f"Template not found: {TEMPLATE_PATH}", file=sys.stderr)
    raise SystemExit(1)

template = TEMPLATE_PATH.read_text(encoding="utf-8")

md = markdown.Markdown(extensions=["extra", "tables", "fenced_code", "toc"])

pages = []

for md_path in sorted(DOCS_DIR.glob("*.md")):
    if md_path.name.startswith("_"):
        continue
    md.reset()
    raw = md_path.read_text(encoding="utf-8")
    html_body = md.convert(raw)
    title = md.toc_tokens[0]["name"] if md.toc_tokens else md_path.stem.replace("-", " ").title()
    description = f"{title} documentation for SW Foundation."

    slug = md_path.stem
    out_dir = DOCS_DIR / slug
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / "index.html"
    canonical = f"{SITE_BASE_URL}/docs/{slug}/"

    page_html = template
    page_html = page_html.replace("{{TITLE}}", title)
    page_html = page_html.replace("{{DESCRIPTION}}", description)
    page_html = page_html.replace("{{CANONICAL}}", canonical)
    page_html = page_html.replace("{{CONTENT}}", html_body)
    out_path.write_text(page_html, encoding="utf-8")

    pages.append({
        "title": title,
        "url": f"/docs/{slug}/",
        "canonical": canonical,
        "source": md_path,
        "lastmod": datetime.fromtimestamp(md_path.stat().st_mtime, tz=timezone.utc).strftime("%Y-%m-%d"),
    })

# Docs index page
if pages:
    items = "\n".join([
        f"<li><a href=\"{escape(p['url'])}\">{escape(p['title'])}</a></li>" for p in pages
    ])
    content = f"<h1>Documentation</h1><p>Guides for SW Foundation packages.</p><ul>{items}</ul>"
    index_html = template
    index_html = index_html.replace("{{TITLE}}", "Documentation")
    index_html = index_html.replace("{{DESCRIPTION}}", "SW Foundation documentation index.")
    index_html = index_html.replace("{{CANONICAL}}", f"{SITE_BASE_URL}/docs/")
    index_html = index_html.replace("{{CONTENT}}", content)
    (DOCS_DIR / "index.html").write_text(index_html, encoding="utf-8")

# Sitemap
now = datetime.now(timezone.utc).strftime("%Y-%m-%d")
def xml_escape(value: str) -> str:
    return escape(value, {'"': '&quot;', "'": '&apos;'})

urls = [
    f"  <url><loc>{xml_escape(SITE_BASE_URL)}/</loc><lastmod>{now}</lastmod></url>",
    f"  <url><loc>{xml_escape(SITE_BASE_URL)}/docs/</loc><lastmod>{now}</lastmod></url>",
]

for p in pages:
    urls.append(f"  <url><loc>{xml_escape(p['canonical'])}</loc><lastmod>{p['lastmod']}</lastmod></url>")

sitemap = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" + \
          "<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">\n" + \
          "\n".join(urls) + "\n</urlset>\n"
(ROOT / "sitemap.xml").write_text(sitemap, encoding="utf-8")

# Robots
robots = f"User-agent: *\nAllow: /\nSitemap: {SITE_BASE_URL}/sitemap.xml\n"
(ROOT / "robots.txt").write_text(robots, encoding="utf-8")

print(f"Generated {len(pages)} docs pages, docs/index.html, sitemap.xml, robots.txt")
