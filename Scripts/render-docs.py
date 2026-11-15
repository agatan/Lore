#!/usr/bin/env python3
"""Render docs/spec.md and docs/design.md to their HTML versions.

The Markdown files are the source. Run from the repository root:

    python3 Scripts/render-docs.py

Supports the Markdown subset the two documents use: headings, paragraphs,
nested bullet and numbered lists, tables, fenced code, inline code, links,
and bold.
"""
import html
import re
import sys
from pathlib import Path

DOCS = Path(__file__).resolve().parent.parent / "docs"
PAGES = {
    "spec": ("External specification", [("design.html", "Internal design")]),
    "design": ("Implementation reference", [("spec.html", "External specification")]),
}
COMMON_LINKS = [("../PRIVACY.md", "Privacy"), ("recovery.md", "Recovery"), ("testing.md", "Testing")]


def inline(text):
    parts = re.split(r"(`[^`]*`)", text)
    out = []
    for part in parts:
        if part.startswith("`") and part.endswith("`") and len(part) >= 2:
            out.append(f"<code>{html.escape(part[1:-1])}</code>")
            continue
        part = html.escape(part, quote=False)
        part = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", part)
        part = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", link, part)
        out.append(part)
    return "".join(out)


def link(match):
    label, target = match.group(1), match.group(2)
    if target in ("spec.md", "design.md"):
        target = target[:-3] + ".html"
    return f'<a href="{target}">{label}</a>'


def unnumbered(title):
    return re.sub(r"^[\d.]+\s*", "", title)


def slug(title):
    words = unnumbered(title).lower()
    return re.sub(r"[^a-z0-9]+", "-", words).strip("-")


def split_row(line):
    cells = re.split(r"(?<!\\)\|", line.strip().strip("|"))
    return [cell.strip() for cell in cells]


def render_list(lines, start, base_indent):
    """Render the list beginning at lines[start]. Returns (html, next index)."""
    ordered = bool(re.match(r"\s*\d+\.\s", lines[start]))
    tag = "ol" if ordered else "ul"
    out = [f"<{tag}>"]
    i = start
    item = re.compile(r"^(\s*)(?:[-*]|\d+\.)\s+(.*)$")
    while i < len(lines):
        match = item.match(lines[i])
        if not match or len(match.group(1)) < base_indent:
            break
        if len(match.group(1)) > base_indent:
            nested, i = render_list(lines, i, len(match.group(1)))
            out[-1] = out[-1][: -len("</li>")] + "\n" + nested + "\n</li>"
            continue
        out.append(f"<li>{inline(match.group(2))}</li>")
        i += 1
    out.append(f"</{tag}>")
    return "\n".join(out), i


def render_body(lines):
    """Returns (lead html, [(id, title, html)])."""
    lead, sections, current = [], [], None
    i = 0

    def emit(fragment):
        (lead if current is None else current[2]).append(fragment)

    while i < len(lines):
        line = lines[i]
        if not line.strip():
            i += 1
        elif line.startswith("## "):
            title = line[3:].strip()
            current = (slug(title), title, [])
            sections.append(current)
            i += 1
        elif line.startswith("### "):
            emit(f"<h3>{inline(line[4:].strip())}</h3>")
            i += 1
        elif line.startswith("```"):
            i += 1
            code = []
            while not lines[i].startswith("```"):
                code.append(lines[i])
                i += 1
            i += 1
            emit("<pre><code>" + html.escape("\n".join(code)) + "</code></pre>")
        elif line.startswith("|"):
            header = split_row(line)
            i += 2
            rows = []
            while i < len(lines) and lines[i].startswith("|"):
                rows.append(split_row(lines[i]))
                i += 1
            head = "".join(f"<th>{inline(cell)}</th>" for cell in header)
            body = "\n".join(
                "<tr>" + "".join(f"<td>{inline(cell)}</td>" for cell in row) + "</tr>" for row in rows
            )
            emit(f"<table>\n<thead>\n<tr>{head}</tr>\n</thead>\n<tbody>\n{body}\n</tbody>\n</table>")
        elif re.match(r"\s*(?:[-*]|\d+\.)\s", line):
            rendered, i = render_list(lines, i, len(line) - len(line.lstrip()))
            emit(rendered)
        else:
            paragraph = []
            while i < len(lines) and lines[i].strip() and not re.match(r"(#|```|\||\s*(?:[-*]|\d+\.)\s)", lines[i]):
                paragraph.append(lines[i].strip())
                i += 1
            emit(f"<p>{inline(' '.join(paragraph))}</p>")
    return "\n".join(lead), [(sid, title, "\n".join(parts)) for sid, title, parts in sections]


def render(name):
    eyebrow, extra_links = PAGES[name]
    lines = (DOCS / f"{name}.md").read_text(encoding="utf-8").splitlines()
    if not lines[0].startswith("# "):
        sys.exit(f"{name}.md must start with a level-1 heading")
    title = lines[0][2:].strip()
    lead, sections = render_body(lines[1:])
    links = [(f"{name}.md", "Markdown source")] + extra_links + COMMON_LINKS
    nav = "\n".join(f'<a href="#{sid}">{html.escape(unnumbered(t))}</a>' for sid, t, _ in sections)
    body = "\n".join(
        f'<section id="{sid}">\n<h2>{inline(t)}</h2>\n{content}\n</section>' for sid, t, content in sections
    )
    page = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{html.escape(title)}</title>
<link rel="stylesheet" href="reference.css">
</head>
<body>
<!-- Generated from {name}.md by Scripts/render-docs.py. Edit the Markdown, not this file. -->
<header>
<p class="eyebrow">{eyebrow}</p>
<h1>{html.escape(title)}</h1>
<div class="lead">
{lead}
</div>
<p class="links">
{chr(10).join(f'<a href="{href}">{label}</a>' for href, label in links)}
</p>
</header>
<nav>
{nav}
</nav>
<main>
{body}
</main>
<footer>Generated from <a href="{name}.md">{name}.md</a>.</footer>
</body>
</html>
"""
    (DOCS / f"{name}.html").write_text(page, encoding="utf-8")
    print(f"wrote docs/{name}.html ({len(sections)} sections)")


for page_name in PAGES:
    render(page_name)
