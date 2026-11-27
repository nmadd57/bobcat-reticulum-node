#!/usr/bin/env python3
"""Render docs/*.md as static HTML pages for the web flasher's /docs/ section.

    python3 tools/build-docs.py --out site/docs

Every page shares the flasher's look (light and dark, one column, readable on a phone). Links between documents become
links between pages, links to files elsewhere in the repository become GitHub links, images are copied, and a broken
link anywhere fails the build. Needs the `markdown` package (pip install markdown).
"""
import argparse
import html
import posixpath
import re
import shutil
import sys
from pathlib import Path

import markdown

REPO = "https://github.com/nmadd57/bobcat-reticulum-node"
ROOT = Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"

# One line per document, in the order the index lists them.
ABOUT = [
    ("recovery-mode", "Putting the unit in recovery mode", "Which buttons to press, which USB port to use, and how to tell it worked."),
    ("usb-flashing", "How USB flashing works", "The two phases, why download mode alone is not enough, and what was tested on real units."),
    ("web-interface", "The node's web interface", "Turning on the rnsd web interface, signing in, the certificate warning and managing the service."),
    ("config-reference", "Settings reference", "Every setting the installer understands, as a file key and as a command-line option."),
    ("self-recovery", "Self-recovery", "Persistent logs, the hardware and network watchdogs, and how to turn them off."),
    ("hardware-notes", "Hardware notes", "What is known about the board: radio, SPI, reset line, LEDs, bootloader."),
    ("maskrom-recovery", "Maskrom recovery", "Getting a unit back whose bootloader is damaged."),
    ("development-notes", "Development notes", "Gotchas found while building the images and the installer."),
]

CSS = """
:root{color-scheme:light dark;--bg:#fbfaf8;--fg:#1d1b1a;--mut:#6b6560;--line:#ddd7d0;--card:#fff;--red:#c8001e;--code:#f3efea}
@media (prefers-color-scheme:dark){:root{--bg:#161413;--fg:#efe9e3;--mut:#a39b93;--line:#3a3532;--card:#1e1b1a;--red:#ff4a5f;--code:#12100f}}
*{box-sizing:border-box}
html{-webkit-text-size-adjust:100%;scroll-padding-top:12px}
body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.6 system-ui,-apple-system,"Segoe UI",sans-serif;overflow-wrap:anywhere}
.wrap{max-width:760px;margin:0 auto;padding:16px 16px 56px}
.top{display:flex;gap:12px;align-items:center;justify-content:space-between;flex-wrap:wrap;padding-bottom:12px;margin-bottom:18px;border-bottom:1px solid var(--line)}
.top a.brand{display:flex;gap:10px;align-items:center;color:var(--fg);text-decoration:none;font-weight:700}
.top img{width:44px;height:auto}
.top nav{display:flex;gap:16px;flex-wrap:wrap;font-size:.92rem}
a{color:var(--red)}
h1{font-size:1.6rem;line-height:1.25;margin:0 0 14px}
h2{font-size:1.25rem;margin:28px 0 8px;line-height:1.3}
h3{font-size:1.05rem;margin:22px 0 6px}
h1 .anchor,h2 .anchor,h3 .anchor{opacity:0;margin-left:.3em;text-decoration:none;font-weight:400}
h1:hover .anchor,h2:hover .anchor,h3:hover .anchor{opacity:.6}
p,ul,ol{margin:0 0 12px}
li{margin:4px 0}
code{background:var(--code);padding:1px 5px;border-radius:4px;font-size:.88em}
pre{margin:0 0 14px;padding:12px;background:var(--code);border:1px solid var(--line);border-radius:8px;font:13px/1.5 ui-monospace,Menlo,Consolas,monospace;white-space:pre-wrap;overflow-wrap:anywhere}
pre code{background:none;padding:0;font-size:inherit}
img{max-width:100%;height:auto;border-radius:8px;border:1px solid var(--line);display:block;margin:12px 0 4px}
em{color:var(--mut)}
blockquote{margin:0 0 14px;padding:8px 14px;border-left:4px solid var(--red);background:var(--card);border-radius:0 8px 8px 0}
blockquote p{margin:0}
.tablewrap{overflow-x:auto;margin:0 0 14px;border:1px solid var(--line);border-radius:8px}
table{border-collapse:collapse;width:100%;font-size:.92rem}
th,td{padding:8px 10px;text-align:left;vertical-align:top;border-bottom:1px solid var(--line)}
th{background:var(--card)}
tr:last-child td{border-bottom:0}
td,th{min-width:7rem}
.cards{display:grid;gap:12px;margin:18px 0}
.cards a{display:block;padding:14px 16px;border:1px solid var(--line);background:var(--card);border-radius:10px;text-decoration:none;color:var(--fg)}
.cards a:hover,.cards a:focus-visible{border-color:var(--red)}
.cards strong{display:block;color:var(--red);margin-bottom:2px}
.cards span{color:var(--mut);font-size:.92rem}
footer{margin-top:36px;padding-top:14px;border-top:1px solid var(--line);color:var(--mut);font-size:.85rem}
"""


def page(title, body, rel_root, source=None):
    """Wrap rendered HTML in the shared page. `rel_root` leads back to the flasher's root ('../' for /docs/x.html)."""
    edit = f' <a href="{REPO}/blob/main/docs/{source}">Edit this page on GitHub</a>.' if source else ""
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{html.escape(title)} · Bobcat 300 Reticulum Flasher</title>
<style>{CSS}</style>
</head>
<body>
<div class="wrap">
<div class="top">
  <a class="brand" href="{rel_root}"><img src="{rel_root}logo.svg" alt=""><span>Bobcat 300 Reticulum Flasher</span></a>
  <nav><a href="{rel_root}">Flasher</a><a href="{rel_root}docs/">Documentation</a><a href="{REPO}">Source</a></nav>
</div>
{body}
<footer>Unofficial: not made by, affiliated with or endorsed by Bobcat, Bobber or Helium.{edit}</footer>
</div>
</body>
</html>
"""


def rewrite_links(body, src_name, known, problems):
    """Turn repo-relative links in a rendered document into links that work on the published site."""
    def fix(m):
        attr, url = m.group(1), m.group(2)
        if re.match(r"^(https?:|mailto:|#|data:)", url):
            return m.group(0)
        path, _, frag = url.partition("#")
        frag = "#" + frag if frag else ""
        target = posixpath.normpath(posixpath.join("docs", path))          # path from the repo root
        if target.startswith("docs/") and target.endswith(".md"):
            stem = target[5:-3]
            if stem not in known:
                problems.append(f"{src_name}: link to a document that does not exist: {url}")
                return m.group(0)
            return f'{attr}="{stem}.html{frag}"'
        if target.startswith("docs/images/"):
            if not (ROOT / target).exists():
                problems.append(f"{src_name}: missing image: {url}")
            return f'{attr}="{target[5:]}{frag}"'
        if target.startswith(".."):
            problems.append(f"{src_name}: link leaves the repository: {url}")
            return m.group(0)
        full = ROOT / target
        if not full.exists():
            problems.append(f"{src_name}: link to a file that does not exist: {url}")
            return m.group(0)
        kind = "tree" if full.is_dir() else "blob"
        return f'{attr}="{REPO}/{kind}/main/{target}{frag}"'
    return re.sub(r'(href|src)="([^"]*)"', fix, body)


def render(md_text):
    md = markdown.Markdown(extensions=["tables", "fenced_code", "toc", "sane_lists", "attr_list"],
                           extension_configs={"toc": {"permalink": "#", "permalink_class": "anchor", "permalink_title": "Link to this section"}})
    body = md.convert(md_text)
    body = re.sub(r"(<table>.*?</table>)", r'<div class="tablewrap">\1</div>', body, flags=re.S)
    return body, md


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--out", required=True, help="output directory, e.g. site/docs")
    a = ap.parse_args()
    out = Path(a.out)
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)

    sources = sorted(p for p in DOCS.glob("*.md"))
    known = {p.stem for p in sources}
    listed = {s for s, _, _ in ABOUT}
    problems = [f"docs/{s}.md is not listed in ABOUT in tools/build-docs.py" for s in sorted(known - listed)]
    problems += [f"ABOUT lists docs/{s}.md, which does not exist" for s in sorted(listed - known)]

    for p in sources:
        body, _ = render(p.read_text(encoding="utf-8"))
        body = rewrite_links(body, p.name, known, problems)
        m = re.search(r"<h1[^>]*>(.*?)</h1>", body, flags=re.S)
        title = re.sub(r"<[^>]+>|\s*#\s*$", "", m.group(1)).strip() if m else p.stem
        (out / f"{p.stem}.html").write_text(page(title, body, "../", p.name), encoding="utf-8")

    cards = "\n".join(f'<a href="{s}.html"><strong>{html.escape(t)}</strong><span>{html.escape(d)}</span></a>' for s, t, d in ABOUT if s in known)
    index = f"""<h1>Documentation</h1>
<p>How the Bobcat 300 Reticulum Flasher works, and how to get a unit into the state it needs.</p>
<div class="cards">
{cards}
</div>
<p>Back to the <a href="../">flasher</a>.</p>"""
    (out / "index.html").write_text(page("Documentation", index, "../"), encoding="utf-8")

    images = DOCS / "images"
    if images.is_dir():
        shutil.copytree(images, out / "images")

    if problems:
        print("documentation build failed:", file=sys.stderr)
        for line in problems:
            print("  " + line, file=sys.stderr)
        return 1
    print(f"wrote {len(sources) + 1} pages to {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
