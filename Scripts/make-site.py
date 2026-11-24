#!/usr/bin/env python3
"""Builds LP's small public website (for Google's app review and anyone curious) from the
repository's own policies, so the published pages always say exactly what the app's do.

    Scripts/make-site.py [output folder]      # default: ../LTF-Git-Dev.github.io

Writes index.html (what LP is and what it does with Google and Microsoft data), privacy.html,
terms.html, cookies.html, connected-accounts.html, security.html, license.html and 404.html, the
stylesheet assets/site.css and the icon. The screenshots in assets/shots/ are made by
Scripts/make-site-shots.sh (run it again when LP's look changes); this script only checks that
they are there.

Nothing private goes in: no email address unless SUPPORT_EMAIL below is set to a dedicated one.
The pages load nothing from anywhere else (no fonts, scripts, analytics or trackers): their
Content Security Policy allows only the site's own stylesheet and images.

The folder is meant to be its own public GitHub Pages repository; pushing it is a separate,
deliberate step.
"""

from __future__ import annotations

import hashlib
import html
import pathlib
import re
import shutil
import struct
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
OUT = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else (REPO.parent / "LTF-Git-Dev.github.io")
SITE_URL = "https://ltf-git-dev.github.io/"

# A dedicated support address (never a personal one). Empty: no contact line.
SUPPORT_EMAIL = "ltf.dev.supp@gmail.com"
# Google Search Console's verification file (googleXXXX.html) for the site's one verified owner,
# ltf.dev.supp@gmail.com — the account that owns the Google Cloud project. (The owner's personal
# account was removed as an owner on 2026-11-20, with its file.)
SEARCH_CONSOLE_FILES = ["google9ca82f03251b9bc1.html"]

PAGES = {  # source in the repository → page on the site
    "PRIVACY.md": ("privacy.html", "Privacy Policy"),
    "TERMS.md": ("terms.html", "Terms of Use"),
    "COOKIES.md": ("cookies.html", "Cookie Policy"),
    "docs/CONNECTED_ACCOUNTS.md": ("connected-accounts.html", "Connected Accounts"),
    "SECURITY.md": ("security.html", "Security"),
}
# Where links between the files go on the site (anything else local is shown as plain text).
LINKS = {source: page for source, (page, _) in PAGES.items()}
LINKS.update({"../PRIVACY.md": "privacy.html", "LICENSE": "license.html", "docs/../PRIVACY.md": "privacy.html"})

# Only the site's own files, nothing inline: no scripts at all, styles from assets/site.css.
CSP = "default-src 'none'; img-src 'self'; style-src 'self'; base-uri 'none'; form-action 'none'"

# The screenshots: Scripts/make-site-shots.sh writes <name>-light.avif, <name>-dark.avif and a
# <name>-light.jpg fallback for each into assets/shots/. The text is each one's alt text.
SHOTS = {
    "home": "LP's Home screen: a greeting with today's date, buttons for a new page, today's note, "
            "a new board and search, the pages you worked on recently, and your open tasks.",
    "notes": "A page in LP's editor: a heading, a numbered list of goals and this week's to-dos "
             "with their due dates.",
    "calendar": "LP's calendar: a month of events with today's daily note, and a Today panel with "
                "today's events and what's due.",
    "progress": "A board's progress panel: 33% done, the cards in each list, how many are overdue or "
                "due soon, how many were done this week and how long cards take to finish.",
    "board": "A board in LP: Backlog, In progress and Review lists of cards with due dates and "
             "labels, under the board's progress bar.",
    "slash": "The menu that opens when you type a slash in LP's editor: text, three sizes of heading, a "
             "to-do list, a bulleted list and a numbered list.",
    "search": "LP's search: typing a word finds the page named after it and every page that mentions "
              "it, or creates a new page with that name.",
}

# Icons from Phosphor Icons (regular weight), MIT License, Copyright (c) 2023 Phosphor Icons: path
# data only (see license.html). Never draw icons by hand; take them from the same set.
ICONS = {
    "arrow-right": "M221.66,133.66l-72,72a8,8,0,0,1-11.32-11.32L196.69,136H40a8,8,0,0,1,0-16H196.69L138.34,61.66a8,8,0,0,1,11.32-11.32l72,72A8,8,0,0,1,221.66,133.66Z",
    "calendar-blank": "M208,32H184V24a8,8,0,0,0-16,0v8H88V24a8,8,0,0,0-16,0v8H48A16,16,0,0,0,32,48V208a16,16,0,0,0,16,16H208a16,16,0,0,0,16-16V48A16,16,0,0,0,208,32ZM72,48v8a8,8,0,0,0,16,0V48h80v8a8,8,0,0,0,16,0V48h24V80H48V48ZM208,208H48V96H208V208Z",
    "chart-line-up": "M232,208a8,8,0,0,1-8,8H32a8,8,0,0,1-8-8V48a8,8,0,0,1,16,0V156.69l50.34-50.35a8,8,0,0,1,11.32,0L128,132.69,180.69,80H160a8,8,0,0,1,0-16h40a8,8,0,0,1,8,8v40a8,8,0,0,1-16,0V91.31l-58.34,58.35a8,8,0,0,1-11.32,0L96,123.31l-56,56V200H224A8,8,0,0,1,232,208Z",
    "cloud-slash": "M53.92,34.62A8,8,0,1,0,42.08,45.38L81.32,88.55l-.06.12A65,65,0,0,0,72,88a64,64,0,0,0,0,128h88a87.34,87.34,0,0,0,31.8-5.93l10.28,11.31a8,8,0,1,0,11.84-10.76ZM160,200H72a48,48,0,0,1,0-96c1.1,0,2.2,0,3.3.12A88.4,88.4,0,0,0,72,128a8,8,0,0,0,16,0,72.25,72.25,0,0,1,5.06-26.54l87,95.7A71.66,71.66,0,0,1,160,200Zm88-72a87.89,87.89,0,0,1-22.35,58.61A8,8,0,0,1,213.71,176,72,72,0,0,0,117.37,70a8,8,0,0,1-9.48-12.89A88,88,0,0,1,248,128Z",
    "envelope-simple": "M224,48H32a8,8,0,0,0-8,8V192a16,16,0,0,0,16,16H216a16,16,0,0,0,16-16V56A8,8,0,0,0,224,48ZM203.43,64,128,133.15,52.57,64ZM216,192H40V74.19l82.59,75.71a8,8,0,0,0,10.82,0L216,74.19V192Z",
    "eye-slash": "M53.92,34.62A8,8,0,1,0,42.08,45.38L61.32,66.55C25,88.84,9.38,123.2,8.69,124.76a8,8,0,0,0,0,6.5c.35.79,8.82,19.57,27.65,38.4C61.43,194.74,93.12,208,128,208a127.11,127.11,0,0,0,52.07-10.83l22,24.21a8,8,0,1,0,11.84-10.76Zm47.33,75.84,41.67,45.85a32,32,0,0,1-41.67-45.85ZM128,192c-30.78,0-57.67-11.19-79.93-33.25A133.16,133.16,0,0,1,25,128c4.69-8.79,19.66-33.39,47.35-49.38l18,19.75a48,48,0,0,0,63.66,70l14.73,16.2A112,112,0,0,1,128,192Zm6-95.43a8,8,0,0,1,3-15.72,48.16,48.16,0,0,1,38.77,42.64,8,8,0,0,1-7.22,8.71,6.39,6.39,0,0,1-.75,0,8,8,0,0,1-8-7.26A32.09,32.09,0,0,0,134,96.57Zm113.28,34.69c-.42.94-10.55,23.37-33.36,43.8a8,8,0,1,1-10.67-11.92A132.77,132.77,0,0,0,231.05,128a133.15,133.15,0,0,0-23.12-30.77C185.67,75.19,158.78,64,128,64a118.37,118.37,0,0,0-19.36,1.57A8,8,0,1,1,106,49.79,134,134,0,0,1,128,48c34.88,0,66.57,13.26,91.66,38.35,18.83,18.83,27.3,37.62,27.65,38.41A8,8,0,0,1,247.31,131.26Z",
    "folder-simple": "M216,72H130.67L102.93,51.2a16.12,16.12,0,0,0-9.6-3.2H40A16,16,0,0,0,24,64V200a16,16,0,0,0,16,16H216.89A15.13,15.13,0,0,0,232,200.89V88A16,16,0,0,0,216,72Zm0,128H40V64H93.33L123.2,86.4A8,8,0,0,0,128,88h88Z",
    "kanban": "M216,48H40a8,8,0,0,0-8,8V208a16,16,0,0,0,16,16H88a16,16,0,0,0,16-16V160h48v16a16,16,0,0,0,16,16h40a16,16,0,0,0,16-16V56A8,8,0,0,0,216,48ZM88,208H48V128H88Zm0-96H48V64H88Zm64,32H104V64h48Zm56,32H168V128h40Zm0-64H168V64h40Z",
    "magnifying-glass": "M229.66,218.34l-50.07-50.06a88.11,88.11,0,1,0-11.31,11.31l50.06,50.07a8,8,0,0,0,11.32-11.32ZM40,112a72,72,0,1,1,72,72A72.08,72.08,0,0,1,40,112Z",
    "key": "M216.57,39.43A80,80,0,0,0,83.91,120.78L28.69,176A15.86,15.86,0,0,0,24,187.31V216a16,16,0,0,0,16,16H72a8,8,0,0,0,8-8V208H96a8,8,0,0,0,8-8V184h16a8,8,0,0,0,5.66-2.34l9.56-9.57A79.73,79.73,0,0,0,160,176h.1A80,80,0,0,0,216.57,39.43ZM224,98.1c-1.09,34.09-29.75,61.86-63.89,61.9H160a63.7,63.7,0,0,1-23.65-4.51,8,8,0,0,0-8.84,1.68L116.69,168H96a8,8,0,0,0-8,8v16H72a8,8,0,0,0-8,8v16H40V187.31l58.83-58.82a8,8,0,0,0,1.68-8.84A63.72,63.72,0,0,1,96,95.92c0-34.14,27.81-62.8,61.9-63.89A64,64,0,0,1,224,98.1ZM192,76a12,12,0,1,1-12-12A12,12,0,0,1,192,76Z",
    "keyboard": "M224,48H32A16,16,0,0,0,16,64V192a16,16,0,0,0,16,16H224a16,16,0,0,0,16-16V64A16,16,0,0,0,224,48Zm0,144H32V64H224V192Zm-16-64a8,8,0,0,1-8,8H56a8,8,0,0,1,0-16H200A8,8,0,0,1,208,128Zm0-32a8,8,0,0,1-8,8H56a8,8,0,0,1,0-16H200A8,8,0,0,1,208,96ZM72,160a8,8,0,0,1-8,8H56a8,8,0,0,1,0-16h8A8,8,0,0,1,72,160Zm96,0a8,8,0,0,1-8,8H96a8,8,0,0,1,0-16h64A8,8,0,0,1,168,160Zm40,0a8,8,0,0,1-8,8h-8a8,8,0,0,1,0-16h8A8,8,0,0,1,208,160Z",
    "note-pencil": "M229.66,58.34l-32-32a8,8,0,0,0-11.32,0l-96,96A8,8,0,0,0,88,128v32a8,8,0,0,0,8,8h32a8,8,0,0,0,5.66-2.34l96-96A8,8,0,0,0,229.66,58.34ZM124.69,152H104V131.31l64-64L188.69,88ZM200,76.69,179.31,56,192,43.31,212.69,64ZM224,128v80a16,16,0,0,1-16,16H48a16,16,0,0,1-16-16V48A16,16,0,0,1,48,32h80a8,8,0,0,1,0,16H48V208H208V128a8,8,0,0,1,16,0Z",
    "shield-check": "M208,40H48A16,16,0,0,0,32,56v56c0,52.72,25.52,84.67,46.93,102.19,23.06,18.86,46,25.26,47,25.53a8,8,0,0,0,4.2,0c1-.27,23.91-6.67,47-25.53C198.48,196.67,224,164.72,224,112V56A16,16,0,0,0,208,40Zm0,72c0,37.07-13.66,67.16-40.6,89.42A129.3,129.3,0,0,1,128,223.62a128.25,128.25,0,0,1-38.92-21.81C61.82,179.51,48,149.3,48,112l0-56,160,0ZM82.34,141.66a8,8,0,0,1,11.32-11.32L112,148.69l50.34-50.35a8,8,0,0,1,11.32,11.32l-56,56a8,8,0,0,1-11.32,0Z",
}

PHOSPHOR_LICENSE = """MIT License

Copyright (c) 2023 Phosphor Icons

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
"""


# MARK: - Markdown (the subset the policies use)

def inline(text: str) -> str:
    codes: list[str] = []

    def keep_code(match):
        codes.append(match.group(1))
        return f"\x00{len(codes) - 1}\x00"

    text = re.sub(r"`([^`]+)`", keep_code, text)
    text = html.escape(text, quote=False)
    text = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"(?<![*\w])\*(?!\s)(.+?)(?<!\s)\*(?![*\w])", r"<em>\1</em>", text)

    def link(match):
        label, target = match.group(1), match.group(2)
        if target.startswith(("http://", "https://", "mailto:")):
            return f'<a href="{html.escape(target)}">{label}</a>'
        page = LINKS.get(target.split("#")[0])
        return f'<a href="{page}">{label}</a>' if page else label

    text = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", link, text)
    return re.sub("\x00(\\d+)\x00", lambda m: f"<code>{html.escape(codes[int(m.group(1))])}</code>", text)


def plain(rendered: str) -> str:
    """Text of rendered inline HTML (for the table of contents, titles and anchors)."""
    return html.unescape(re.sub(r"<[^>]+>", "", rendered))


def slug(text: str, used: set[str]) -> str:
    base = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-") or "section"
    candidate, n = base, 2
    while candidate in used:
        candidate, n = f"{base}-{n}", n + 1
    used.add(candidate)
    return candidate


def indent_of(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def parse_list(lines: list[str], i: int, indent: int) -> tuple[str, int]:
    items = []
    while i < len(lines):
        line = lines[i]
        if not line.strip():
            # A list goes on after a blank line only with another item at its level.
            if i + 1 < len(lines) and indent_of(lines[i + 1]) == indent and lines[i + 1].lstrip().startswith("- "):
                i += 1
                continue
            break
        if indent_of(line) != indent or not line.lstrip().startswith("- "):
            break
        parts: list[tuple[str, str]] = [("text", line.strip()[2:])]
        i += 1
        while i < len(lines) and lines[i].strip() and indent_of(lines[i]) > indent:
            if lines[i].lstrip().startswith("- "):
                sub, i = parse_list(lines, i, indent_of(lines[i]))
                parts.append(("list", sub))
            else:
                if parts[-1][0] == "text":
                    parts[-1] = ("text", parts[-1][1] + " " + lines[i].strip())
                else:
                    parts.append(("text", lines[i].strip()))
                i += 1
        body = ""
        for n, (kind, value) in enumerate(parts):
            if kind == "list":
                body += value
            else:
                body += inline(value) if n == 0 else f"<p>{inline(value)}</p>"
        items.append(f"<li>{body}</li>")
    return "<ul>" + "".join(items) + "</ul>", i


def table(rows: list[str]) -> str:
    cells = [[c.strip() for c in row.strip().strip("|").split("|")] for row in rows]
    head, body = cells[0], [r for r in cells[2:]]
    out = ('<div class="table" role="region" aria-label="Table" tabindex="0"><table><thead><tr>'
           + "".join(f'<th scope="col">{inline(c)}</th>' for c in head) + "</tr></thead><tbody>")
    for row in body:
        out += "<tr>" + "".join(f"<td>{inline(c)}</td>" for c in row) + "</tr>"
    return out + "</tbody></table></div>"


def markdown(source: str) -> dict:
    """The document's HTML (without its title), its title, the italic note under the title (when
    there is one, e.g. "Last updated: …") and its sections for the table of contents."""
    lines = source.splitlines()
    out: list[str] = []
    toc: list[tuple[str, str]] = []
    used: set[str] = set()
    title, meta, i = "", "", 0
    while i < len(lines):
        line = lines[i]
        if not line.strip():
            i += 1
            continue
        heading = re.match(r"(#{1,4}) (.*)", line)
        if heading:
            level, text = len(heading.group(1)), heading.group(2).strip()
            i += 1
            if level == 1 and not title:
                title = inline(text)
                j = i
                while j < len(lines) and not lines[j].strip():
                    j += 1
                note = re.fullmatch(r"\*([^*\s].*[^*\s])\*", lines[j].strip()) if j < len(lines) else None
                if note:
                    meta, i = inline(note.group(1)), j + 1
                continue
            rendered = inline(text)
            ident = slug(plain(rendered), used)
            if level == 2:
                toc.append((ident, plain(rendered)))
            out.append(f'<h{level} id="{ident}">{rendered}</h{level}>')
        elif line.startswith("|"):
            start = i
            while i < len(lines) and lines[i].startswith("|"):
                i += 1
            out.append(table(lines[start:i]))
        elif line.lstrip().startswith("- "):
            block, i = parse_list(lines, i, indent_of(line))
            out.append(block)
        else:
            paragraph = []
            while i < len(lines) and lines[i].strip() and not re.match(r"(#{1,4} |\||\s*- )", lines[i]):
                paragraph.append(lines[i].strip())
                i += 1
            out.append(f"<p>{inline(' '.join(paragraph))}</p>")
    return {"html": "\n".join(out), "title": title, "meta": meta, "toc": toc}


# MARK: - Style

STYLE = """
/* LP's website. Generated by Scripts/make-site.py: edit it there, not here.
   Tokens (light, then dark) → base → header → home → document pages → footer → motion.
   Shapes: chips 8px, controls 12px, screenshots 14px, cards 20px, the Get LP band 28px.
   Colours were measured: every text colour clears WCAG AA (4.5:1) on every surface it sits on. */

:root {
  color-scheme: light dark;
  --font: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
  --mono: ui-monospace, "SF Mono", SFMono-Regular, Menlo, Consolas, monospace;
  --bg: #ffffff; --bg-2: #f5f5f7; --surface: #ffffff;
  --ink: #1d1d1f; --ink-2: #515156; --ink-3: #6b6b70;
  --line: #e5e5ea; --line-2: #d2d2d7;
  --link: #1a63cc; --button: #1a63cc; --button-press: #1554ad; --on-button: #ffffff; --focus: #1a63cc;
  --code: #f0f0f3;
  --header: rgb(255 255 255 / .8);
  --hero: #0c1424; --hero-2: #13203a; --hero-ink: #f5f7fb; --hero-ink-2: #b8c2d2;
  --hero-line: rgb(255 255 255 / .26); --hero-dots: rgb(255 255 255 / .13);
  --glow-a: rgb(84 196 206 / .30); --glow-b: rgb(59 130 246 / .34); --glow-c: rgb(244 160 176 / .16);
  --tint-sky: #eaf2fd; --tint-mint: #e5f5f2; --tint-rose: #fdeef1;
  --tint-lilac: #f0edfc; --tint-sand: #fbf4e4; --tint-slate: #f1f2f5;
  --hue-sky: #1a63cc; --hue-mint: #0b7a72; --hue-rose: #c0395a;
  --hue-lilac: #6447d6; --hue-sand: #9a5b00; --hue-slate: #4b5363;
  --chip: rgb(255 255 255 / .85);
  --shot-line: rgb(0 0 0 / .07);
  --shadow-card: 0 1px 2px rgb(16 24 40 / .05), 0 18px 40px -22px rgb(16 24 40 / .30);
  --shadow-hero: 0 0 0 1px rgb(0 0 0 / .06), 0 2px 10px rgb(2 6 18 / .22), 0 60px 120px -40px rgb(2 6 18 / .65);
  --wrap: 1180px; --gutter: clamp(20px, 4vw, 32px); --section: clamp(84px, 10vw, 140px);
  --ease: cubic-bezier(.16, 1, .3, 1);
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #0e0e10; --bg-2: #161618; --surface: #1c1c1f;
    --ink: #f2f2f4; --ink-2: #b4b4ba; --ink-3: #8f8f96;
    --line: #2a2a2e; --line-2: #3a3a3f;
    --link: #5aa5ff; --button: #2b6fd8; --button-press: #2463c4; --focus: #5aa5ff;
    --code: #232327;
    --header: rgb(14 14 16 / .74);
    --hero: #080d18; --hero-2: #0f1a30;
    --glow-a: rgb(84 196 206 / .20); --glow-b: rgb(59 130 246 / .30); --glow-c: rgb(244 160 176 / .10);
    --tint-sky: #121c2c; --tint-mint: #10231f; --tint-rose: #261519;
    --tint-lilac: #1b1830; --tint-sand: #241e10; --tint-slate: #1a1b1f;
    --hue-sky: #6aa8ff; --hue-mint: #4fd1c5; --hue-rose: #ff8fa3;
    --hue-lilac: #a995ff; --hue-sand: #f0b44c; --hue-slate: #a9adb8;
    --chip: rgb(255 255 255 / .08);
    --shot-line: rgb(255 255 255 / .09);
    --shadow-card: 0 1px 2px rgb(0 0 0 / .4), 0 18px 40px -22px rgb(0 0 0 / .85);
    --shadow-hero: 0 0 0 1px rgb(255 255 255 / .08), 0 2px 10px rgb(0 0 0 / .4), 0 60px 120px -40px rgb(0 0 0 / .9);
  }
}

/* Base */
*, *::before, *::after { box-sizing: border-box; }
html { -webkit-text-size-adjust: 100%; text-size-adjust: 100%; scroll-padding-top: 88px; }
body {
  margin: 0; background: var(--bg); color: var(--ink);
  font: 400 17px/1.6 var(--font); -webkit-font-smoothing: antialiased; -moz-osx-font-smoothing: grayscale;
}
img { display: block; max-width: 100%; height: auto; }
a { color: var(--link); text-decoration: none; text-underline-offset: .2em; }
a:hover { text-decoration: underline; }
h1, h2, h3, h4 { margin: 0; color: var(--ink); font-weight: 700; text-wrap: balance; }
p { margin: 0; text-wrap: pretty; }
code { font: 500 .86em/1.4 var(--mono); background: var(--code); border-radius: 6px; padding: .12em .42em; overflow-wrap: anywhere; }
:focus-visible { outline: 3px solid var(--focus); outline-offset: 3px; border-radius: 6px; }
main:focus { outline: none; }
.wrap { width: min(100% - 2 * var(--gutter), var(--wrap)); margin-inline: auto; }
.icon { width: 1.15em; height: 1.15em; fill: currentColor; flex: none; }
.nowrap { white-space: nowrap; }
.skip-link {
  position: absolute; left: 16px; top: -120px; z-index: 30; padding: 12px 18px; border-radius: 12px;
  background: var(--surface); color: var(--ink); font-weight: 600; box-shadow: var(--shadow-card);
}
.skip-link:focus { top: 12px; text-decoration: none; }

/* Buttons */
.button {
  display: inline-flex; align-items: center; justify-content: center; gap: 9px; min-height: 48px;
  padding: 12px 22px; border: 1px solid transparent; border-radius: 12px;
  font: 600 16px/1.2 var(--font); white-space: nowrap;
  transition: background-color .18s ease, border-color .18s ease, transform .18s var(--ease);
}
.button:hover { text-decoration: none; }
.button:active { transform: scale(.98); }
.button .icon { width: 18px; height: 18px; }
.button-primary { background: var(--button); color: var(--on-button); }
.button-primary:hover { background: var(--button-press); }
.button-ghost { background: rgb(255 255 255 / .05); border-color: var(--hero-line); color: var(--hero-ink); }
.button-ghost:hover { background: rgb(255 255 255 / .11); border-color: rgb(255 255 255 / .42); }

/* Header */
.site-header {
  position: sticky; top: 0; z-index: 20; border-bottom: 1px solid var(--line);
  background: var(--header); -webkit-backdrop-filter: saturate(180%) blur(18px); backdrop-filter: saturate(180%) blur(18px);
}
.header-row { display: flex; align-items: center; justify-content: space-between; gap: 20px; min-height: 64px; }
.brand {
  display: inline-flex; align-items: center; gap: 10px; padding: 8px 4px 8px 0;
  color: var(--ink); font-size: 19px; font-weight: 700; letter-spacing: -.01em;
}
.brand img { width: 30px; height: 30px; }
.brand:hover { text-decoration: none; }
.site-nav { display: flex; align-items: center; gap: 2px; }
.site-nav a { padding: 10px 12px; border-radius: 10px; color: var(--ink-2); font-size: 15px; font-weight: 500; }
.site-nav a:hover { background: var(--bg-2); color: var(--ink); text-decoration: none; }
.site-nav a[aria-current="page"] { color: var(--ink); font-weight: 600; }
@media (max-width: 720px) {
  .site-header { position: static; }
  .header-row { flex-wrap: wrap; gap: 0; min-height: 0; padding-top: 6px; }
  .site-nav {
    flex: 1 0 100%; margin-inline: calc(-1 * var(--gutter)); padding: 0 var(--gutter) 6px;
    overflow-x: auto; scrollbar-width: none;
    -webkit-mask-image: linear-gradient(90deg, transparent, #000 var(--gutter), #000 calc(100% - var(--gutter)), transparent);
    mask-image: linear-gradient(90deg, transparent, #000 var(--gutter), #000 calc(100% - var(--gutter)), transparent);
  }
  .site-nav::-webkit-scrollbar { display: none; }
  .site-nav a { padding: 12px; white-space: nowrap; }
  .site-nav a:first-child { padding-left: 0; }
}

/* Home: hero */
.hero { --tail: clamp(90px, 17vw, 260px); position: relative; isolation: isolate; padding-top: clamp(52px, 6.5vw, 92px); }
.hero::before, .hero::after { content: ""; position: absolute; inset: 0 0 var(--tail) 0; pointer-events: none; }
.hero::before {
  z-index: -2;
  background:
    radial-gradient(42% 55% at 10% 6%, var(--glow-a), transparent 72%),
    radial-gradient(46% 58% at 90% 12%, var(--glow-b), transparent 72%),
    radial-gradient(44% 44% at 50% 104%, var(--glow-c), transparent 76%),
    linear-gradient(180deg, var(--hero) 0%, var(--hero-2) 100%);
}
.hero::after {
  z-index: -1;
  background-image: radial-gradient(var(--hero-dots) 1px, transparent 1.5px);
  background-size: 24px 24px;
  -webkit-mask-image: radial-gradient(64% 58% at 50% 26%, #000, transparent 78%);
  mask-image: radial-gradient(64% 58% at 50% 26%, #000, transparent 78%);
}
.hero-copy { display: flex; flex-direction: column; align-items: center; text-align: center; color: var(--hero-ink); }
.hero-icon { width: 92px; height: 92px; margin-bottom: 16px; filter: drop-shadow(0 16px 30px rgb(0 0 0 / .45)); }
.hero h1 {
  max-width: 13.5em; color: var(--hero-ink);
  font-size: clamp(2.4rem, 1.1rem + 4.3vw, 4.4rem); line-height: 1.04; letter-spacing: -.038em;
}
.hero-lead {
  max-width: 33em; margin-top: 22px; color: var(--hero-ink-2);
  font-size: clamp(1.125rem, 1rem + .45vw, 1.3125rem); line-height: 1.5;
}
.actions { display: flex; flex-wrap: wrap; justify-content: center; gap: 12px; margin-top: 34px; }
.hero :focus-visible { outline-color: #ffffff; }
.hero-shot { margin-top: clamp(44px, 5.5vw, 72px); }
.hero-shot img { width: 100%; border-radius: 14px; box-shadow: var(--shadow-hero); }

/* Home: sections */
.section { padding-block: var(--section); }
.section-head { max-width: 46rem; margin-bottom: clamp(40px, 5vw, 64px); }
.section h2 { font-size: clamp(2rem, 1.3rem + 2.4vw, 3.1rem); line-height: 1.07; letter-spacing: -.03em; }
.section-head p, .lead {
  margin-top: 18px; max-width: 38em; color: var(--ink-2);
  font-size: clamp(1.0625rem, 1rem + .3vw, 1.25rem); line-height: 1.55;
}
.features { padding-top: clamp(72px, 9vw, 120px); }

/* Home: the feature grid */
.bento { display: grid; grid-template-columns: repeat(12, minmax(0, 1fr)); gap: clamp(14px, 1.6vw, 20px); }
.tile {
  --pad: clamp(22px, 2.6vw, 32px);
  grid-column: 1 / -1; display: flex; flex-direction: column; overflow: hidden;
  padding: var(--pad) var(--pad) 0; border-radius: 20px; background: var(--tile);
}
.tile-sky { --tile: var(--tint-sky); --hue: var(--hue-sky); }
.tile-mint { --tile: var(--tint-mint); --hue: var(--hue-mint); }
.tile-rose { --tile: var(--tint-rose); --hue: var(--hue-rose); }
.tile-lilac { --tile: var(--tint-lilac); --hue: var(--hue-lilac); }
.tile-sand { --tile: var(--tint-sand); --hue: var(--hue-sand); }
.tile-slate { --tile: var(--tint-slate); --hue: var(--hue-slate); }
.tile-icon {
  display: inline-grid; place-items: center; width: 40px; height: 40px; margin-bottom: 18px;
  border-radius: 11px; background: var(--chip); color: var(--hue); box-shadow: 0 1px 2px rgb(16 24 40 / .06);
}
.tile-icon .icon { width: 22px; height: 22px; }
.tile h3 { font-size: clamp(1.25rem, 1.1rem + .4vw, 1.5rem); line-height: 1.2; letter-spacing: -.02em; }
.tile p { max-width: 30em; margin-top: 10px; color: var(--ink-2); font-size: 16px; line-height: 1.55; }
.tile-media { position: relative; flex: 1 1 auto; min-height: 0; margin-top: clamp(22px, 3vw, 32px); }
.tile-media picture { display: contents; }
.tile-media.bleed { aspect-ratio: 16 / 10; margin-right: calc(-1 * var(--pad)); overflow: hidden; border-top-left-radius: 14px; box-shadow: var(--shadow-card); }
.tile-media.bleed img {
  position: absolute; inset: 0; width: 100%; height: 100%; max-width: none;
  object-fit: cover; object-position: left top;
}
.tile-media.bleed::after { content: ""; position: absolute; inset: 0; border-top-left-radius: inherit; box-shadow: inset 1px 1px 0 var(--shot-line); pointer-events: none; }
.tile-media.float { display: flex; align-items: center; justify-content: center; padding-bottom: var(--pad); }
.tile-media.float img {
  width: auto; height: auto; max-height: 100%; border-radius: 16px;
  box-shadow: 0 0 0 1px var(--shot-line), var(--shadow-card);
}
.tile-media img.shot-progress { max-width: min(100%, 315px); }
.tile-media img.shot-slash { max-width: min(100%, 284px); border-radius: 11px; }
.tile-media img.shot-search { max-width: min(100%, 560px); border-radius: 12px; }
@media (min-width: 700px) { .tile { grid-column: span 6; } }
@media (min-width: 900px) {
  .tile { height: clamp(500px, 44vw, 580px); }
  .tile-media.bleed { aspect-ratio: auto; }
  .span-7 { grid-column: span 7; }
  .span-6 { grid-column: span 6; }
  .span-5 { grid-column: span 5; }
}

/* Home: privacy */
.privacy { background: var(--bg-2); }
.privacy-grid { display: grid; gap: clamp(36px, 5vw, 72px); align-items: start; }
.facts { display: grid; gap: 14px; grid-template-columns: repeat(auto-fit, minmax(min(100%, 250px), 1fr)); }
.fact { padding: 26px; border: 1px solid var(--line); border-radius: 20px; background: var(--surface); }
.fact .tile-icon { margin-bottom: 16px; background: var(--tile); }
.fact h3 { font-size: 1.125rem; line-height: 1.3; letter-spacing: -.012em; }
.fact p { margin-top: 6px; color: var(--ink-2); font-size: 15.5px; line-height: 1.55; }
@media (min-width: 960px) { .privacy-grid { grid-template-columns: 5fr 7fr; } }

/* Home: how LP uses Google and Microsoft data */
.data .ledger, .data .callout, .data .after, .data .link-row { max-width: 960px; }
.ledger { margin-top: 44px; border: 1px solid var(--line); border-radius: 20px; background: var(--surface); }
.ledger-row { display: grid; gap: 14px 40px; padding: 28px clamp(22px, 3vw, 32px); }
.ledger-row + .ledger-row { border-top: 1px solid var(--line); }
.ledger-name h3 { font-size: 1.1875rem; letter-spacing: -.012em; }
.ledger-name p { margin-top: 4px; color: var(--ink-3); font-size: 14.5px; line-height: 1.45; }
.scopes { display: grid; gap: 16px; margin: 0; }
.scopes div { display: grid; gap: 6px; justify-items: start; }
.scopes dt code { font-size: 14px; }
.scopes dd { margin: 0; color: var(--ink-2); font-size: 16px; line-height: 1.55; }
.ledger-note { color: var(--ink-3); font-size: 15px; line-height: 1.5; }
@media (min-width: 760px) {
  .ledger-row { grid-template-columns: 210px minmax(0, 1fr); }
  .ledger-row > :not(.ledger-name) { grid-column: 2; }
}
.callout { display: flex; gap: 16px; margin-top: 28px; padding: 24px clamp(22px, 3vw, 28px); border-radius: 20px; background: var(--tint-sky); }
.callout .icon { width: 26px; height: 26px; margin-top: 2px; color: var(--hue-sky); }
.callout p { font-size: 16px; line-height: 1.6; }
.callout a { text-decoration: underline; }
.after { margin-top: 28px; color: var(--ink-2); }
.link-row { display: flex; flex-wrap: wrap; gap: 6px 26px; margin-top: 14px; }
.link-row a { display: inline-flex; align-items: center; gap: 6px; min-height: 44px; font-weight: 600; }
.link-row .icon { width: 16px; height: 16px; }

/* Home: Get LP */
.band {
  display: grid; gap: 26px; align-items: center; padding: clamp(32px, 5vw, 56px); border: 1px solid var(--line); border-radius: 28px;
  background:
    radial-gradient(60% 130% at 0% 0%, var(--tint-mint), transparent 70%),
    radial-gradient(60% 130% at 100% 100%, var(--tint-sky), transparent 70%),
    var(--bg-2);
}
.band img { width: 104px; height: 104px; filter: drop-shadow(0 12px 22px rgb(16 24 40 / .22)); }
.band h2 { font-size: clamp(1.75rem, 1.35rem + 1.5vw, 2.5rem); }
.band p { margin-top: 10px; color: var(--ink-2); font-size: 1.0625rem; }
.band .button { justify-self: start; }
.get { padding-top: 0; }
@media (min-width: 860px) { .band { grid-template-columns: auto minmax(0, 1fr) auto; gap: 36px; } }

/* Document pages (policies) */
.doc-head { padding: clamp(48px, 7vw, 92px) 0 clamp(36px, 5vw, 56px); border-bottom: 1px solid var(--line); background: var(--bg-2); }
.doc-head h1 { font-size: clamp(2.25rem, 1.45rem + 2.7vw, 3.5rem); line-height: 1.05; letter-spacing: -.035em; }
.doc-meta { margin-top: 14px; color: var(--ink-3); font-size: 15px; }
.doc-layout { display: grid; gap: 48px; padding-block: clamp(40px, 6vw, 72px) var(--section); }
.toc { display: none; }
@media (min-width: 1040px) {
  .doc-layout.has-toc { grid-template-columns: 220px minmax(0, 1fr); gap: 72px; }
  .toc { display: block; position: sticky; top: 96px; align-self: start; max-height: calc(100vh - 120px); overflow: auto; }
}
.toc-title { margin-bottom: 10px; color: var(--ink); font-size: 13px; font-weight: 600; }
.toc ol { margin: 0; padding: 0; list-style: none; border-left: 1px solid var(--line); }
.toc a { display: block; margin-left: -1px; padding: 6px 0 6px 14px; border-left: 2px solid transparent; color: var(--ink-3); font-size: 14px; line-height: 1.4; }
.toc a:hover { border-left-color: var(--line-2); color: var(--ink); text-decoration: none; }
.prose { min-width: 0; max-width: 72ch; font-size: 17px; line-height: 1.7; }
.prose > :first-child { margin-top: 0; }
.prose h2 { margin: 56px 0 14px; font-size: clamp(1.5rem, 1.3rem + .6vw, 1.875rem); line-height: 1.2; letter-spacing: -.022em; scroll-margin-top: 96px; }
.prose h3 { margin: 36px 0 10px; font-size: 1.25rem; line-height: 1.3; letter-spacing: -.012em; scroll-margin-top: 96px; }
.prose h4 { margin: 28px 0 8px; font-size: 1.0625rem; }
.prose p { margin: 14px 0; }
.prose ul { margin: 14px 0; padding-left: 1.3em; }
.prose li { margin: 8px 0; padding-left: .2em; }
.prose li::marker { color: var(--ink-3); }
.prose li > ul { margin: 6px 0; }
.prose li p { margin: 8px 0 0; }
.prose a { text-decoration: underline; text-decoration-thickness: 1px; }
.prose strong { font-weight: 650; }
.table { margin: 22px 0; overflow-x: auto; border: 1px solid var(--line); border-radius: 14px; }
.prose table { width: 100%; border-collapse: collapse; font-size: 15px; line-height: 1.5; }
.prose th, .prose td { padding: 12px 16px; text-align: left; vertical-align: top; }
.prose thead th { background: var(--bg-2); color: var(--ink); font-weight: 600; }
.prose tbody tr + tr td { border-top: 1px solid var(--line); }
.prose pre {
  margin: 18px 0; padding: 20px 22px; border: 1px solid var(--line); border-radius: 14px;
  background: var(--bg-2); white-space: pre-wrap; font: 14px/1.6 var(--mono);
}

/* Not found */
.notfound { display: flex; flex-direction: column; align-items: center; padding-block: clamp(96px, 14vw, 180px); text-align: center; }
.notfound img { width: 96px; height: 96px; margin-bottom: 22px; }
.notfound h1 { font-size: clamp(2.25rem, 1.6rem + 2.4vw, 3.25rem); letter-spacing: -.03em; }
.notfound p { margin: 14px 0 30px; color: var(--ink-2); font-size: 1.125rem; }

/* Footer */
.site-footer { padding: 56px 0 36px; border-top: 1px solid var(--line); color: var(--ink-2); font-size: 15px; }
.footer-grid { display: grid; gap: 32px 24px; grid-template-columns: repeat(auto-fit, minmax(170px, 1fr)); }
.footer-brand p { max-width: 22em; margin-top: 10px; line-height: 1.55; }
.footer-col h2 { margin-bottom: 8px; color: var(--ink); font-size: 13px; font-weight: 600; letter-spacing: .01em; }
.footer-col ul { display: grid; margin: 0; padding: 0; list-style: none; }
.footer-col a { display: inline-flex; align-items: center; min-height: 40px; color: var(--ink-2); }
.footer-col a:hover { color: var(--ink); }
.footer-base {
  display: flex; flex-wrap: wrap; justify-content: space-between; gap: 8px 24px;
  margin-top: 40px; padding-top: 22px; border-top: 1px solid var(--line); color: var(--ink-3); font-size: 14px;
}
@media (min-width: 900px) { .footer-grid { grid-template-columns: 2fr 1fr 1.25fr 1.4fr; } }

/* Motion: an entrance for the hero and a gentle reveal as each part scrolls in. None of it when
   the visitor asks for less motion; the reveal only where the browser ties it to scrolling. */
@media (prefers-reduced-motion: no-preference) {
  html { scroll-behavior: smooth; }
  .hero-copy > * { animation: rise .9s var(--ease) both; }
  .hero-copy > :nth-child(2) { animation-delay: .06s; }
  .hero-copy > :nth-child(3) { animation-delay: .12s; }
  .hero-copy > :nth-child(4) { animation-delay: .18s; }
  .hero-shot { animation: rise-far 1.1s .22s var(--ease) both; }
  @supports (animation-timeline: view()) {
    .reveal { animation: rise-far linear both; animation-timeline: view(); animation-range: entry 0% entry 55%; }
  }
}
@keyframes rise { from { opacity: 0; transform: translateY(18px); } to { opacity: 1; transform: none; } }
@keyframes rise-far { from { opacity: 0; transform: translateY(36px); } to { opacity: 1; transform: none; } }

@media (prefers-reduced-transparency: reduce) {
  .site-header { background: var(--bg); -webkit-backdrop-filter: none; backdrop-filter: none; }
}
@media (forced-colors: active) {
  .tile, .fact, .ledger, .band, .callout, .button { border: 1px solid CanvasText; }
}
@media print {
  .site-header, .site-footer, .toc, .skip-link { display: none; }
  .hero-copy > *, .hero-shot, .reveal { animation: none !important; }
  .doc-head { background: none; }
  .prose a { color: inherit; }
}
"""
CSS_VERSION = hashlib.sha256(STYLE.encode()).hexdigest()[:10]


# MARK: - Pieces

def icon(name: str) -> str:
    return f'<svg class="icon" viewBox="0 0 256 256" aria-hidden="true" focusable="false"><path d="{ICONS[name]}"/></svg>'


def jpeg_size(path: pathlib.Path) -> tuple[int, int]:
    data, i = path.read_bytes(), 2
    while i + 9 < len(data):
        if data[i] != 0xFF:
            i += 1
            continue
        marker = data[i + 1]
        if marker in (0xC0, 0xC1, 0xC2):
            height, width = struct.unpack(">HH", data[i + 5:i + 9])
            return width, height
        if marker == 0xFF or marker == 0x01 or 0xD0 <= marker <= 0xD8:
            i += 2 if marker != 0xFF else 1
            continue
        i += 2 + struct.unpack(">H", data[i + 2:i + 4])[0]
    sys.exit(f"Couldn't read the size of {path}")


def picture(name: str, image_class: str = "", eager: bool = False) -> str:
    """A screenshot in LP's light or dark look, following the visitor's setting; a JPEG for
    browsers without AVIF."""
    width, height = jpeg_size(OUT / "assets/shots" / f"{name}-light.jpg")
    # The first screen's image loads at once and decodes normally (an async decode can leave it
    # blank while its entrance animation runs); the rest load lazily.
    loading = 'fetchpriority="high"' if eager else 'loading="lazy" decoding="async"'
    css = f' class="{image_class}"' if image_class else ""
    return (f'<picture>'
            f'<source type="image/avif" media="(prefers-color-scheme: dark)" srcset="assets/shots/{name}-dark.avif">'
            f'<source type="image/avif" srcset="assets/shots/{name}-light.avif">'
            f'<img{css} src="assets/shots/{name}-light.jpg" width="{width}" height="{height}" '
            f'alt="{html.escape(SHOTS[name])}" {loading}>'
            f'</picture>')


NAV = [("Features", "#features"), ("Your data", "#data"), ("Privacy", "privacy.html"),
       ("Terms", "terms.html"), ("Security", "security.html")]


def header(path: str, root: str) -> str:
    home = "#top" if path == "" else (root or "./")
    links = []
    for label, href in NAV:
        target = (href if path == "" else f"{root or './'}{href}") if href.startswith("#") else f"{root}{href}"
        current = ' aria-current="page"' if href == path else ""
        links.append(f'<a href="{target}"{current}>{label}</a>')
    return f"""<header class="site-header" id="top">
  <div class="wrap header-row">
    <a class="brand" href="{home}"><img src="{root}icon.png" width="30" height="30" alt=""><span>LP</span></a>
    <nav class="site-nav" aria-label="Main">{"".join(links)}</nav>
  </div>
</header>"""


def footer(path: str, root: str) -> str:
    def at(href: str) -> str:
        if href.startswith("#"):
            return href if path == "" else f"{root or './'}{href}"
        return f"{root}{href}"

    policies = [("Privacy Policy", "privacy.html"), ("Terms of Use", "terms.html"), ("Cookie Policy", "cookies.html"),
                ("Connected Accounts", "connected-accounts.html"), ("Security", "security.html"), ("MIT License", "license.html")]
    contact = (f'<div class="footer-col"><h2>Contact</h2><ul><li><a href="mailto:{SUPPORT_EMAIL}">{SUPPORT_EMAIL}</a></li></ul></div>'
               if SUPPORT_EMAIL else "")
    return f"""<footer class="site-footer">
  <div class="wrap">
    <div class="footer-grid">
      <div class="footer-brand">
        <a class="brand" href="{at('#top') if path == '' else (root or './')}"><img src="{root}icon.png" width="30" height="30" alt=""><span>LP</span></a>
        <p>A calm Mac app for notes, calendars and project boards, on your own Markdown files.</p>
      </div>
      <nav class="footer-col" aria-labelledby="footer-lp"><h2 id="footer-lp">LP</h2><ul>
        <li><a href="{at('#features')}">Features</a></li><li><a href="{at('#data')}">Your data</a></li><li><a href="{at('#get-lp')}">Get LP</a></li>
      </ul></nav>
      <nav class="footer-col" aria-labelledby="footer-policies"><h2 id="footer-policies">Policies</h2><ul>
        {"".join(f'<li><a href="{at(href)}">{label}</a></li>' for label, href in policies)}
      </ul></nav>
      {contact}
    </div>
    <div class="footer-base"><p>© 2026 LTF-Git-Dev</p><p>LP stands for Local Productivity.</p></div>
  </div>
</footer>"""


def page(*, title: str, description: str, path: str | None, body: str, root: str = "") -> str:
    """A whole page. `path` is its address on the site ("" for the home page; None for the
    not-found page, which links from the site's root because it answers at any address)."""
    canonical = f'<link rel="canonical" href="{SITE_URL}{path}">\n' if path is not None else '<meta name="robots" content="noindex">\n'
    where = path if path is not None else "404.html"  # the header and footer link back home from it
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="{CSP}">
<meta name="referrer" content="strict-origin-when-cross-origin">
<title>{html.escape(title)}</title>
<meta name="description" content="{html.escape(description)}">
{canonical}<meta name="color-scheme" content="light dark">
<meta name="theme-color" content="#ffffff" media="(prefers-color-scheme: light)">
<meta name="theme-color" content="#0e0e10" media="(prefers-color-scheme: dark)">
<meta property="og:type" content="website">
<meta property="og:site_name" content="LP">
<meta property="og:title" content="{html.escape(title)}">
<meta property="og:description" content="{html.escape(description)}">
<meta property="og:url" content="{SITE_URL}{path or ''}">
<meta property="og:image" content="{SITE_URL}icon.png">
<meta name="twitter:card" content="summary">
<link rel="icon" href="{root}icon.png" type="image/png">
<link rel="apple-touch-icon" href="{root}icon.png">
<link rel="stylesheet" href="{root}assets/site.css?v={CSS_VERSION}">
</head>
<body>
<a class="skip-link" href="#main">Skip to content</a>
{header(where, root)}
<main id="main" tabindex="-1">
{body}
</main>
{footer(where, root)}
</body>
</html>
"""


# MARK: - Pages

FEATURES = [  # (screenshot, width, colour, icon, title, text, how the screenshot sits)
    ("notes", "span-7", "sky", "note-pencil", "Notes that are just files",
     "A clean editor over your own Markdown files, compatible with Obsidian. Nothing is uploaded: the files stay "
     "where you keep them.", "bleed"),
    ("calendar", "span-5", "mint", "calendar-blank", "Every calendar, two-way",
     "Your Apple, Google and Outlook calendars next to your notes. Events you create or change in LP are saved back "
     "to the calendar they belong to.", "bleed"),
    ("progress", "span-5", "lilac", "chart-line-up", "Progress at a glance",
     "Each board shows what’s done, what’s overdue and how long cards take to finish.", "float"),
    ("board", "span-7", "rose", "kanban", "Boards in plain Markdown",
     "Kanban boards stored as Markdown files. When you want to, share a read-only progress page with a link.", "bleed"),
    ("slash", "span-6", "sand", "keyboard", "Quick from the keyboard",
     "Type / to add a heading, a to-do list or another block without reaching for the mouse.", "float"),
    ("search", "span-6", "slate", "magnifying-glass", "Find anything",
     "Press ⌘K (or ⌘P) and type: LP finds pages by their name and by what’s inside them, and opens the one you pick.",
     "float"),
]

FACTS = [  # (icon, colour, title, text)
    ("folder-simple", "sky", "Plain files",
     "Every page and board is a Markdown file in a folder you choose. Any text editor can open it."),
    ("cloud-slash", "mint", "No servers, no account",
     "There’s nothing to sign up for. LP goes online only for the calendars you connect, the boards you share "
     "and a daily look for a new version on GitHub, which you can turn off."),
    ("key", "sand", "Sign-ins stay on your Mac",
     "A connected account’s sign-in is kept in your Mac’s Keychain. The people who make LP never see it."),
    ("eye-slash", "rose", "No tracking",
     "No analytics, no telemetry and no ads. Nothing about how you use LP is sent anywhere."),
]

CLAUDE_FACTS = [  # (icon, colour, title, text) — LP with Claude (1.0.2)
    ("shield-check", "mint", "You choose, every time",
     "Before Claude reads or changes anything, LP itself asks you which workspace — and which folder in it — it may use. "
     "(In the Claude desktop app, one choice may last across its chats.)"),
    ("folder-simple", "sky", "Only what you chose",
     "Claude reaches nothing else and can’t delete files. If you save a page in LP or Obsidian while Claude changes it, "
     "your save stands."),
    ("kanban", "lilac", "Notes, tasks and boards",
     "Search and read pages, write to today’s note, tick tasks off, add and move cards — with the files staying plain Markdown."),
    ("key", "sand", "Runs on your Mac",
     "LP’s helper has no network access of its own. What Claude reads goes to Anthropic, as with anything you share with Claude."),
]

LEDGER = [  # (service, when, [(permission, what LP does with it)], note)
    ("Google Calendar", "", [
        ("calendar.calendarlist.readonly", "Shows the list of your calendars."),
        ("calendar.events", "Shows your events in LP, and creates, changes or deletes events when you do so in LP."),
    ], "LP keeps a copy of a year back to two years ahead on your Mac, so your calendar works offline."),
    ("Google Drive", "Only if you choose to share a board there", [
        ("drive.file", "Creates, updates and deletes the progress pages you share, as Google Docs in your own Drive. "
                       "It can’t see or change any other file in your Drive."),
    ], ""),
    ("Microsoft Outlook", "", [
        ("Calendars.ReadWrite", "Shows and edits your calendars’ events in LP."),
        ("offline_access", "Keeps LP connected after you sign in."),
    ], ""),
]


def home() -> str:
    tiles = []
    for shot, width, colour, symbol, title, text, sits in FEATURES:
        image_class = f"shot-{shot}" if sits == "float" else ""
        tiles.append(f"""<article class="tile tile-{colour} {width} reveal">
        <span class="tile-icon">{icon(symbol)}</span>
        <h3>{title}</h3>
        <p>{text}</p>
        <div class="tile-media {sits}">{picture(shot, image_class)}</div>
      </article>""")
    facts = "".join(f"""<div class="fact tile-{colour}"><span class="tile-icon">{icon(symbol)}</span><h3>{title}</h3><p>{text}</p></div>"""
                    for symbol, colour, title, text in FACTS)
    claude_facts = "".join(f"""<div class="fact tile-{colour}"><span class="tile-icon">{icon(symbol)}</span><h3>{title}</h3><p>{text}</p></div>"""
                           for symbol, colour, title, text in CLAUDE_FACTS)
    rows = []
    for service, when, scopes, note in LEDGER:
        when_html = f"<p>{when}</p>" if when else ""
        scope_html = "".join(f"<div><dt><code>{scope}</code></dt><dd>{use}</dd></div>" for scope, use in scopes)
        note_html = f'<p class="ledger-note">{note}</p>' if note else ""
        rows.append(f"""<div class="ledger-row">
          <div class="ledger-name"><h3>{service}</h3>{when_html}</div>
          <dl class="scopes">{scope_html}</dl>{note_html}
        </div>""")
    contact = (f"""<p>Questions or problems? Write to <span class="nowrap">{SUPPORT_EMAIL}</span>.</p>""" if SUPPORT_EMAIL else "")
    # The download: the newest official release (the support address stays in the line above).
    contact_button = f"""<a class="button button-primary" href="https://github.com/LTF-Git-Dev/local-productivity/releases/latest">Download LP{icon("arrow-right")}</a>"""
    body = f"""<section class="hero" aria-labelledby="hero-title">
  <div class="wrap hero-copy">
    <img class="hero-icon" src="icon.png" width="92" height="92" alt="LP">
    <h1 id="hero-title">Notes, calendar and boards in one calm Mac app.</h1>
    <p class="hero-lead">LP keeps every page in plain Markdown files, in a folder you choose. No account, no servers, no tracking.</p>
    <div class="actions">
      <a class="button button-primary" href="#features">Explore LP{icon("arrow-right")}</a>
      <a class="button button-ghost" href="#data">Your data</a>
    </div>
  </div>
  <div class="wrap hero-shot">{picture("home", eager=True)}</div>
</section>

<section class="section features" id="features" aria-labelledby="features-title">
  <div class="wrap">
    <div class="section-head">
      <h2 id="features-title">Write, plan and track in the same window.</h2>
      <p>Pages and boards are plain files you own, and your calendars sit right next to them.</p>
    </div>
    <div class="bento">
      {"".join(tiles)}
    </div>
  </div>
</section>

<section class="section privacy" id="claude" aria-labelledby="claude-title">
  <div class="wrap privacy-grid">
    <div>
      <h2 id="claude-title">Work with Claude.</h2>
      <p class="lead">New in LP 1.0.2: Claude Code and the Claude desktop app can read, write and update your notes,
      tasks and boards. Ask “What’s overdue?” or “Plan my week on a board”.</p>
      <p class="lead">For Claude Code, turn it on in <strong>Settings › General › LP with Claude</strong>: follow its four
      short steps in Terminal. The desktop app is set up by hand (see the user guide).</p>
    </div>
    <div class="facts">{claude_facts}</div>
  </div>
</section>

<section class="section privacy" aria-labelledby="privacy-title">
  <div class="wrap privacy-grid">
    <div>
      <h2 id="privacy-title">Your files stay yours.</h2>
      <p class="lead">LP is an app, not a service. Your notes, boards and calendar copy live on your Mac, and none of it
      is sent to the people who make LP.</p>
    </div>
    <div class="facts">{facts}</div>
  </div>
</section>

<section class="section data" id="data" aria-labelledby="data-title">
  <div class="wrap">
    <h2 id="data-title">How LP uses your Google and Microsoft data</h2>
    <p class="lead">LP connects to Google or Microsoft only when you click <strong>Connect</strong> and approve on their own
    page. Every request goes straight from your Mac to them: LP has <strong>no servers, no accounts, no analytics and no
    ads</strong>, and the people who make LP never receive your data or your sign-in, which stays in your Mac’s Keychain.</p>
    <div class="ledger">
        {"".join(rows)}
    </div>
    <div class="callout">{icon("shield-check")}<p>LP’s use and transfer of information received from Google APIs adheres to the
    <a href="https://developers.google.com/terms/api-services-user-data-policy">Google API Services User Data Policy</a>,
    including the Limited Use requirements. Your data is used only to show and edit your calendar in LP on your Mac and to
    publish the board pages you choose to share; it is never sold, never transferred to anyone else, never used for
    advertising, and never read by people.</p></div>
    <p class="after">Disconnecting an account in LP removes LP’s copy and asks Google to end LP’s access; you can also
    remove LP’s access any time in your Google or Microsoft account settings.</p>
    <p class="after"><strong>Coming soon:</strong> one-click Google Connect — Google is still reviewing LP. Until then,
    add your Google account in System Settings → Internet Accounts and LP shows its calendars through Apple Calendar, or
    connect with your own Google Cloud client ID (Settings → Calendars → Use Your Own Client ID).</p>
    <p class="link-row"><a href="privacy.html">Privacy Policy{icon("arrow-right")}</a><a href="terms.html">Terms of Use{icon("arrow-right")}</a><a href="connected-accounts.html">What each connected account allows{icon("arrow-right")}</a></p>
  </div>
</section>

<section class="section get" id="get-lp" aria-labelledby="get-title">
  <div class="wrap">
    <div class="band">
      <img src="icon.png" width="104" height="104" alt="">
      <div>
        <h2 id="get-title">Get LP</h2>
        <p>LP runs on macOS 15 and later. It is free, and its code is under the <a href="license.html">MIT License</a>.</p>
        <p><strong>Opening it the first time:</strong> LP isn’t from the App Store, so macOS may say it “could not verify LP is
        free of malware”. Click Done, open System Settings → Privacy &amp; Security, and click <strong>Open Anyway</strong>
        next to the message about LP. You only do this once; updates from inside LP don’t ask again.</p>
        {contact}
      </div>
      {contact_button}
    </div>
  </div>
</section>"""
    return page(title="LP: notes, calendar and boards on your Mac", path="", body=body,
                description="LP is a calm Mac app for notes, calendars and project boards, on plain Markdown files in a "
                            "folder you choose. No account, no servers, no tracking.")


def document(doc: dict, fallback_title: str) -> str:
    toc = ""
    if len(doc["toc"]) >= 3:
        items = "".join(f'<li><a href="#{ident}">{html.escape(label)}</a></li>' for ident, label in doc["toc"])
        toc = f'<nav class="toc" aria-label="On this page"><p class="toc-title">On this page</p><ol>{items}</ol></nav>'
    meta = f'<p class="doc-meta">{doc["meta"]}</p>' if doc["meta"] else ""
    return f"""<header class="doc-head"><div class="wrap"><h1>{doc["title"] or html.escape(fallback_title)}</h1>{meta}</div></header>
<div class="wrap doc-layout{' has-toc' if toc else ''}">{toc}<article class="prose">
{doc["html"]}
</article></div>"""


def license_page() -> str:
    text = html.escape((REPO / "LICENSE").read_text())
    body = (f'<header class="doc-head"><div class="wrap"><h1>MIT License</h1><p class="doc-meta">LP’s licence</p></div></header>'
            f'<div class="wrap doc-layout"><article class="prose"><pre>{text}</pre>'
            f'<h2 id="icons-on-this-website">Icons on this website</h2>'
            f'<p>The website’s icons come from <a href="https://phosphoricons.com">Phosphor Icons</a>, under this licence:</p>'
            f'<pre>{html.escape(PHOSPHOR_LICENSE)}</pre></article></div>')
    return page(title="MIT License · LP", path="license.html", body=body, description="LP's licence.")


def not_found() -> str:
    body = """<section class="wrap notfound">
  <img src="/icon.png" width="96" height="96" alt="">
  <h1>Page not found</h1>
  <p>There’s no page at this address on LP’s website.</p>
  <a class="button button-primary" href="/">Go to the home page</a>
</section>"""
    return page(title="Page not found · LP", path=None, body=body, root="/",
                description="There's no page at this address on LP's website.")


def check_shots() -> None:
    folder = OUT / "assets/shots"
    missing = [f"assets/shots/{name}-{kind}" for name in SHOTS for kind in ("light.avif", "dark.avif", "light.jpg")
               if not (folder / f"{name}-{kind}").exists()]
    if missing:
        sys.exit("Missing screenshots (make them with Scripts/make-site-shots.sh):\n  " + "\n  ".join(missing))


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    check_shots()
    (OUT / "assets").mkdir(exist_ok=True)
    (OUT / "assets/site.css").write_text(STYLE.lstrip())
    for source, (target, title) in PAGES.items():
        doc = markdown((REPO / source).read_text())
        heading = plain(doc["title"]) if doc["title"] else title
        (OUT / target).write_text(page(title=f"{heading} · LP", path=target, body=document(doc, title),
                                       description=f"LP's {title.lower()}."))
    (OUT / "license.html").write_text(license_page())
    (OUT / "index.html").write_text(home())
    (OUT / "404.html").write_text(not_found())
    shutil.copy(REPO / "Local Productivity/Assets.xcassets/AppIcon.appiconset/icon_256x256.png", OUT / "icon.png")
    (OUT / ".nojekyll").write_text("")
    for name in SEARCH_CONSOLE_FILES:
        (OUT / name).write_text(f"google-site-verification: {name}")
    (OUT / "README.md").write_text(
        "# LP website\n\nLP's public pages (home, privacy policy, terms, cookies, connected accounts, security, "
        "licence), generated from the app's own policies by `Scripts/make-site.py` in the app's repository; the "
        "screenshots in `assets/shots/` come from `Scripts/make-site-shots.sh`. Served by GitHub Pages. Nothing here "
        "loads anything from another site.\n")
    print(f"Wrote {OUT}")


if __name__ == "__main__":
    main()
