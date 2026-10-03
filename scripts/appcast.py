#!/usr/bin/env python3
"""Sparkle appcast and release notes for Captylo releases (stdlib only).

  scripts/appcast.py item <appcast.xml> --version 1.0.0 --build 142
      --url https://captylo.com/download/Captylo-1.0.0.dmg
      (--signature <edSig> --length <bytes> | --sign-update '<sign_update output>')
      --notes https://captylo.com/updates/notes/1.0.0.html [--min-os 14.4]
  scripts/appcast.py notes <notes.md> <out.html> --version 1.0.0
  scripts/appcast.py check <appcast.xml> --version 1.0.0 --build 142 --length <DMG bytes>
  scripts/appcast.py site-version site/index.html --version 1.0.0 [--check]

`item` creates the feed when it does not exist, keeps every other item, replaces the
item with the same build number and keeps the items newest first. `notes` turns a short
Markdown file (headings, paragraphs, "- " lists, **bold**, `code`, [links](https://...))
into the release notes page Sparkle shows next to the update. `check` is the publish guard
(the item exists, is newest, matches the DMG size and carries a real signature).
`site-version` writes the version into every <span data-version> on the page.
Tests: python3 -m unittest scripts/test_appcast.py
"""

import argparse
import html
import os
import re
import sys
import xml.etree.ElementTree as ET
from datetime import datetime
from email.utils import format_datetime

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE_NS)

VERSION_RE = re.compile(r"^\d+\.\d+\.\d+$")
SIGN_UPDATE_RE = re.compile(r'sparkle:edSignature="([^"]+)"\s+length="(\d+)"')


def _sparkle(tag):
    return f"{{{SPARKLE_NS}}}{tag}"


def _require_https(url, what):
    if not url.startswith("https://"):
        raise ValueError(f"{what} must be an https URL: {url}")


def new_feed():
    root = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(root, "channel")
    ET.SubElement(channel, "title").text = "Captylo"
    ET.SubElement(channel, "link").text = "https://captylo.com/"
    ET.SubElement(channel, "description").text = "Aktualizacje Captylo"
    ET.SubElement(channel, "language").text = "pl"
    return root


def load_feed(path):
    if not os.path.exists(path):
        return new_feed()
    root = ET.parse(path).getroot()
    if root.tag != "rss" or root.find("channel") is None:
        raise ValueError(f"{path} is not an RSS feed with a channel")
    return root


def make_item(version, build, url, length, signature, notes_url, min_os, pub_date=None):
    if not VERSION_RE.match(version):
        raise ValueError(f"version must look like 1.2.3: {version}")
    if int(build) <= 0:
        raise ValueError(f"build must be a positive number: {build}")
    if int(length) <= 0:
        raise ValueError(f"length must be a positive number of bytes: {length}")
    if not signature:
        raise ValueError("the EdDSA signature is empty")
    _require_https(url, "the download URL")
    _require_https(notes_url, "the release notes URL")
    when = pub_date or datetime.now().astimezone()

    item = ET.Element("item")
    ET.SubElement(item, "title").text = f"Captylo {version}"
    ET.SubElement(item, "pubDate").text = format_datetime(when)
    ET.SubElement(item, _sparkle("version")).text = str(int(build))
    ET.SubElement(item, _sparkle("shortVersionString")).text = version
    ET.SubElement(item, _sparkle("minimumSystemVersion")).text = min_os
    ET.SubElement(item, _sparkle("releaseNotesLink")).text = notes_url
    ET.SubElement(
        item,
        "enclosure",
        {
            "url": url,
            "length": str(int(length)),
            "type": "application/octet-stream",
            _sparkle("edSignature"): signature,
        },
    )
    return item


def _build_of(item):
    try:
        return int(item.findtext(_sparkle("version")) or 0)
    except ValueError:
        return 0


def _version_of(item):
    return (item.findtext(_sparkle("shortVersionString")) or "").strip()


def upsert_item(root, item):
    """Adds the item, dropping any item with the same build or the same version: a rerun of
    make dist for one version replaces the DMG at the same URL, so an older item would carry a
    length and signature that no longer match it."""
    channel = root.find("channel")
    build = _build_of(item)
    version = _version_of(item)
    items = [
        old
        for old in channel.findall("item")
        if _build_of(old) != build and (not version or _version_of(old) != version)
    ]
    for old in channel.findall("item"):
        channel.remove(old)
    items.append(item)
    items.sort(key=_build_of, reverse=True)
    channel.extend(items)
    return root


def write_feed(root, path):
    ET.indent(root, space="  ")
    directory = os.path.dirname(path)
    if directory:
        os.makedirs(directory, exist_ok=True)
    ET.ElementTree(root).write(path, encoding="utf-8", xml_declaration=True)
    with open(path, "a", encoding="utf-8") as handle:
        handle.write("\n")


def parse_sign_update(text):
    match = SIGN_UPDATE_RE.search(text or "")
    if not match:
        raise ValueError(f"no sparkle:edSignature in the sign_update output: {text.strip()}")
    return match.group(1), int(match.group(2))


# Release notes

def _inline(text):
    out = []
    for part in re.split(r"(`[^`]+`)", text):
        if len(part) >= 2 and part.startswith("`") and part.endswith("`"):
            out.append(f"<code>{html.escape(part[1:-1], quote=False)}</code>")
            continue
        escaped = html.escape(part, quote=False)
        escaped = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", escaped)
        escaped = re.sub(
            r"\[([^\]]+)\]\((https?://[^\s)]+)\)",
            lambda m: f'<a href="{m.group(2).replace(chr(34), "&quot;")}">{m.group(1)}</a>',
            escaped,
        )
        out.append(escaped)
    return "".join(out)


def _blocks(markdown):
    lines = markdown.splitlines()
    body = []
    paragraph = []
    in_list = False

    def flush_paragraph():
        if paragraph:
            body.append(f"<p>{_inline(' '.join(paragraph))}</p>")
            paragraph.clear()

    def close_list():
        nonlocal in_list
        if in_list:
            body.append("</ul>")
            in_list = False

    for raw in lines:
        line = raw.strip()
        heading = re.match(r"^(#{1,3})\s+(.*)$", line)
        bullet = re.match(r"^[-*]\s+(.*)$", line)
        if not line:
            flush_paragraph()
            close_list()
        elif heading:
            flush_paragraph()
            close_list()
            level = len(heading.group(1))
            body.append(f"<h{level}>{_inline(heading.group(2))}</h{level}>")
        elif bullet:
            flush_paragraph()
            if not in_list:
                body.append("<ul>")
                in_list = True
            body.append(f"<li>{_inline(bullet.group(1))}</li>")
        else:
            close_list()
            paragraph.append(line)
    flush_paragraph()
    close_list()
    return body


NOTES_TEMPLATE = """<!DOCTYPE html>
<html lang="pl">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<link rel="stylesheet" href="../../assets/css/site.css?v=20260930a">
<style>
.notes{{width:min(680px,100% - 2*var(--gut));margin:0 auto;padding:32px 0 48px}}
.notes h1{{font-weight:800;font-size:clamp(28px,4.4vw,40px);line-height:1.08;letter-spacing:-.03em}}
.notes h2{{margin-top:32px;font-weight:700;font-size:21px;line-height:1.25;letter-spacing:-.02em}}
.notes h3{{margin-top:22px;font-weight:700;font-size:17px}}
.notes p{{margin-top:12px;line-height:1.6}}
.notes ul{{margin-top:10px;padding-left:22px;list-style:disc;display:grid;gap:6px}}
.notes li{{line-height:1.55}}
.notes a{{text-decoration:underline;text-underline-offset:3px}}
.notes code{{font-size:.92em;padding:1px 5px;border-radius:6px;background:rgba(16,39,44,.06)}}
</style>
</head>
<body>
<main class="notes">
{body}
</main>
</body>
</html>
"""


def render_notes(markdown, version):
    if not VERSION_RE.match(version):
        raise ValueError(f"version must look like 1.2.3: {version}")
    if not markdown.strip():
        raise ValueError("the release notes are empty")
    title = f"Captylo {version}"
    body = _blocks(markdown)
    if not body[0].startswith("<h1>"):
        body.insert(0, f"<h1>{html.escape(title)}</h1>")
    return NOTES_TEMPLATE.format(title=html.escape(title), body="\n".join(body))


# Checks before publishing

def check_release(root, version, build, length):
    """Problems that should stop a publish, as sentences; empty when the feed is ready."""
    problems = []
    items = root.find("channel").findall("item")
    matching = [item for item in items if _build_of(item) == int(build)]
    if not matching:
        return [f"the appcast has no item for build {build}"]
    item = matching[0]
    if items[0] is not item:
        problems.append(f"build {build} is not the newest item in the appcast")
    shown = item.findtext(_sparkle("shortVersionString"))
    if shown != version:
        problems.append(f"build {build} is version {shown} in the appcast, not {version}")
    enclosure = item.find("enclosure")
    if enclosure is None:
        return problems + [f"build {build} has no enclosure"]
    url = enclosure.get("url", "")
    if not url.endswith(f"/Captylo-{version}.dmg"):
        problems.append(f"the enclosure points at {url}, not at Captylo-{version}.dmg")
    signature = enclosure.get(_sparkle("edSignature"), "")
    if not signature or signature == "DRY-RUN-UNSIGNED":
        problems.append("the item carries no EdDSA signature (a dry run item?)")
    if enclosure.get("length") != str(int(length)):
        problems.append(f"the enclosure says {enclosure.get('length')} bytes, the DMG has {length}")
    return problems


# The version on captylo.com: every <span ... data-version ...>x.y.z</span> in the page

SITE_VERSION_RE = re.compile(r"(<span\b[^>]*\bdata-version\b[^>]*>)([^<]*)(</span>)")


def site_versions(page):
    return [match.group(2) for match in SITE_VERSION_RE.finditer(page)]


def set_site_version(page, version):
    if not VERSION_RE.match(version):
        raise ValueError(f"version must look like 1.2.3: {version}")
    updated, count = SITE_VERSION_RE.subn(lambda m: f"{m.group(1)}{version}{m.group(3)}", page)
    if count == 0:
        raise ValueError("the page has no <span data-version> marker")
    return updated, count


# Command line

def _cmd_item(args):
    if args.sign_update:
        signature, length = parse_sign_update(args.sign_update)
    else:
        if not args.signature or args.length is None:
            raise ValueError("give --signature and --length, or --sign-update")
        signature, length = args.signature, args.length
    root = load_feed(args.appcast)
    item = make_item(
        version=args.version,
        build=args.build,
        url=args.url,
        length=length,
        signature=signature,
        notes_url=args.notes,
        min_os=args.min_os,
    )
    upsert_item(root, item)
    write_feed(root, args.appcast)
    print(f"{args.appcast}: Captylo {args.version} (build {args.build}), {length} bytes")


def _cmd_notes(args):
    with open(args.markdown, encoding="utf-8") as handle:
        page = render_notes(handle.read(), args.version)
    directory = os.path.dirname(args.out)
    if directory:
        os.makedirs(directory, exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as handle:
        handle.write(page)
    print(f"{args.out}: release notes for Captylo {args.version}")


def _cmd_check(args):
    problems = check_release(load_feed(args.appcast), args.version, args.build, args.length)
    if problems:
        raise ValueError(f"{args.appcast} is not ready: " + "; ".join(problems))
    print(f"{args.appcast}: Captylo {args.version} (build {args.build}) is signed and newest")


def _cmd_site_version(args):
    with open(args.page, encoding="utf-8") as handle:
        page = handle.read()
    if args.check:
        found = site_versions(page)
        if not found or any(v != args.version for v in found):
            raise ValueError(f"{args.page} shows version {', '.join(found) or 'none'}, not {args.version}")
        print(f"{args.page}: shows {args.version}")
        return
    updated, count = set_site_version(page, args.version)
    if updated != page:
        with open(args.page, "w", encoding="utf-8") as handle:
            handle.write(updated)
    print(f"{args.page}: version {args.version} in {count} place(s)")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)

    item = commands.add_parser("item", help="add or replace one release in the appcast")
    item.add_argument("appcast")
    item.add_argument("--version", required=True)
    item.add_argument("--build", required=True, type=int)
    item.add_argument("--url", required=True)
    item.add_argument("--length", type=int)
    item.add_argument("--signature")
    item.add_argument("--sign-update", help="the line sign_update printed (signature and length)")
    item.add_argument("--notes", required=True, help="release notes URL")
    item.add_argument("--min-os", default="14.4")
    item.set_defaults(run=_cmd_item)

    notes = commands.add_parser("notes", help="render the release notes page")
    notes.add_argument("markdown")
    notes.add_argument("out")
    notes.add_argument("--version", required=True)
    notes.set_defaults(run=_cmd_notes)

    check = commands.add_parser("check", help="is this release in the appcast, signed and newest?")
    check.add_argument("appcast")
    check.add_argument("--version", required=True)
    check.add_argument("--build", required=True, type=int)
    check.add_argument("--length", required=True, type=int, help="size of the DMG in bytes")
    check.set_defaults(run=_cmd_check)

    site = commands.add_parser("site-version", help="write or check the version shown on the site")
    site.add_argument("page")
    site.add_argument("--version", required=True)
    site.add_argument("--check", action="store_true", help="only check, write nothing")
    site.set_defaults(run=_cmd_site_version)

    args = parser.parse_args(argv)
    try:
        args.run(args)
    except (ValueError, OSError, ET.ParseError) as error:
        print(f"appcast.py: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
