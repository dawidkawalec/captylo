"""Tests for scripts/appcast.py: python3 -m unittest scripts/test_appcast.py"""

import os
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import appcast  # noqa: E402

NS = appcast.SPARKLE_NS
WHEN = datetime(2026, 10, 4, 10, 0, 0, tzinfo=timezone(timedelta(hours=2)))


def item_args(version="1.0.0", build=142, signature="c2lnbmF0dXJl", length=31457280):
    return dict(
        version=version,
        build=build,
        url=f"https://captylo.com/download/Captylo-{version}.dmg",
        length=length,
        signature=signature,
        notes_url=f"https://captylo.com/updates/notes/{version}.html",
        min_os="14.4",
        pub_date=WHEN,
    )


def builds(root):
    return [int(item.findtext(f"{{{NS}}}version")) for item in root.iter("item")]


class ItemTests(unittest.TestCase):
    def test_item_has_the_sparkle_fields(self):
        item = appcast.make_item(**item_args())
        self.assertEqual(item.findtext("title"), "Captylo 1.0.0")
        self.assertEqual(item.findtext("pubDate"), "Sun, 04 Oct 2026 10:00:00 +0200")
        self.assertEqual(item.findtext(f"{{{NS}}}version"), "142")
        self.assertEqual(item.findtext(f"{{{NS}}}shortVersionString"), "1.0.0")
        self.assertEqual(item.findtext(f"{{{NS}}}minimumSystemVersion"), "14.4")
        self.assertEqual(
            item.findtext(f"{{{NS}}}releaseNotesLink"),
            "https://captylo.com/updates/notes/1.0.0.html",
        )
        enclosure = item.find("enclosure")
        self.assertEqual(enclosure.get("url"), "https://captylo.com/download/Captylo-1.0.0.dmg")
        self.assertEqual(enclosure.get("length"), "31457280")
        self.assertEqual(enclosure.get("type"), "application/octet-stream")
        self.assertEqual(enclosure.get(f"{{{NS}}}edSignature"), "c2lnbmF0dXJl")

    def test_rejects_bad_input(self):
        for bad in (
            dict(version="1.0"),
            dict(build=0),
            dict(length=0),
            dict(signature=""),
        ):
            with self.subTest(bad=bad):
                with self.assertRaises(ValueError):
                    appcast.make_item(**{**item_args(), **bad})
        with self.assertRaises(ValueError):
            appcast.make_item(**{**item_args(), "url": "http://captylo.com/x.dmg"})


class FeedTests(unittest.TestCase):
    def test_new_feed_has_a_channel_and_no_items(self):
        root = appcast.new_feed()
        self.assertEqual(root.tag, "rss")
        self.assertIsNotNone(root.find("channel"))
        self.assertEqual(builds(root), [])

    def test_upsert_keeps_other_items_and_sorts_newest_first(self):
        root = appcast.new_feed()
        appcast.upsert_item(root, appcast.make_item(**item_args("1.0.0", 142)))
        appcast.upsert_item(root, appcast.make_item(**item_args("1.0.2", 160)))
        appcast.upsert_item(root, appcast.make_item(**item_args("1.0.1", 150)))
        self.assertEqual(builds(root), [160, 150, 142])

    def test_upsert_replaces_the_item_with_the_same_build(self):
        root = appcast.new_feed()
        appcast.upsert_item(root, appcast.make_item(**item_args("1.0.0", 142, signature="old")))
        appcast.upsert_item(root, appcast.make_item(**item_args("1.0.0", 142, signature="new")))
        self.assertEqual(builds(root), [142])
        enclosure = root.find("channel/item/enclosure")
        self.assertEqual(enclosure.get(f"{{{NS}}}edSignature"), "new")

    def test_upsert_replaces_an_older_build_of_the_same_version(self):
        # make dist rerun for 1.0.0 on a later commit: the old item would point at the same DMG
        # URL with a length and signature that no longer match the file.
        root = appcast.new_feed()
        appcast.upsert_item(root, appcast.make_item(**item_args("1.0.0", 74)))
        appcast.upsert_item(root, appcast.make_item(**item_args("1.0.1", 80)))
        appcast.upsert_item(root, appcast.make_item(**item_args("1.0.0", 76)))
        self.assertEqual(builds(root), [80, 76])

    def test_items_stay_after_the_channel_metadata(self):
        root = appcast.new_feed()
        appcast.upsert_item(root, appcast.make_item(**item_args()))
        tags = [child.tag for child in root.find("channel")]
        self.assertEqual(tags[0], "title")
        self.assertEqual(tags[-1], "item")

    def test_round_trip_keeps_the_sparkle_namespace(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "appcast.xml")
            root = appcast.load_feed(path)
            appcast.upsert_item(root, appcast.make_item(**item_args("1.0.0", 142)))
            appcast.write_feed(root, path)
            root = appcast.load_feed(path)
            appcast.upsert_item(root, appcast.make_item(**item_args("1.0.1", 150)))
            appcast.write_feed(root, path)
            with open(path, encoding="utf-8") as handle:
                text = handle.read()
            self.assertIn('xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"', text)
            self.assertNotIn("ns0:", text)
            self.assertIn("<sparkle:version>150</sparkle:version>", text)
            self.assertTrue(text.startswith("<?xml"))
            self.assertEqual(builds(ET.parse(path).getroot()), [150, 142])


class SignUpdateTests(unittest.TestCase):
    def test_parses_the_sign_update_output(self):
        signature, length = appcast.parse_sign_update(
            'sparkle:edSignature="AbC+/12==" length="31457280"\n'
        )
        self.assertEqual(signature, "AbC+/12==")
        self.assertEqual(length, 31457280)

    def test_rejects_output_without_a_signature(self):
        with self.assertRaises(ValueError):
            appcast.parse_sign_update("ERROR! Unable to find a private key")


class NotesTests(unittest.TestCase):
    MD = (
        "# Captylo 1.0.0\n"
        "\n"
        "The first public version.\n"
        "Second line of the paragraph.\n"
        "\n"
        "## New\n"
        "\n"
        "- **Updates** in the app\n"
        "- shortcut `⌃⌥⌘M` and <tag>\n"
        "- [Website](https://captylo.com/)\n"
    )

    def test_renders_headings_lists_and_paragraphs(self):
        html = appcast.render_notes(self.MD, "1.0.0")
        self.assertIn('<html lang="en">', html)
        self.assertIn("<title>Captylo 1.0.0</title>", html)
        self.assertIn("<h1>Captylo 1.0.0</h1>", html)
        self.assertIn("<p>The first public version. Second line of the paragraph.</p>", html)
        self.assertIn("<h2>New</h2>", html)
        self.assertIn("<li><strong>Updates</strong> in the app</li>", html)
        self.assertIn("<li>shortcut <code>⌃⌥⌘M</code> and &lt;tag&gt;</li>", html)
        self.assertIn('<li><a href="https://captylo.com/">Website</a></li>', html)
        self.assertEqual(html.count("<ul>"), 1)

    def test_adds_a_title_heading_when_the_notes_have_none(self):
        html = appcast.render_notes("Bug fixes.\n", "1.0.1")
        self.assertIn("<h1>Captylo 1.0.1</h1>", html)
        self.assertIn("<p>Bug fixes.</p>", html)

    def test_uses_the_site_stylesheet(self):
        html = appcast.render_notes("x\n", "1.0.0")
        self.assertIn('href="../../assets/css/site.css', html)

    def test_refuses_empty_notes(self):
        with self.assertRaises(ValueError):
            appcast.render_notes("  \n\n", "1.0.0")


class CheckReleaseTests(unittest.TestCase):
    def feed(self, **overrides):
        root = appcast.new_feed()
        appcast.upsert_item(root, appcast.make_item(**item_args("1.0.0", 142)))
        appcast.upsert_item(root, appcast.make_item(**item_args(**{"version": "1.0.1", "build": 150, **overrides})))
        return root

    def test_a_published_release_passes(self):
        problems = appcast.check_release(self.feed(), "1.0.1", 150, 31457280)
        self.assertEqual(problems, [])

    def test_missing_build(self):
        problems = appcast.check_release(self.feed(), "1.0.2", 160, 31457280)
        self.assertEqual(len(problems), 1)
        self.assertIn("160", problems[0])

    def test_dry_run_signature_is_refused(self):
        problems = appcast.check_release(self.feed(signature="DRY-RUN-UNSIGNED"), "1.0.1", 150, 31457280)
        self.assertTrue(any("dry run" in p for p in problems), problems)

    def test_length_must_match_the_dmg(self):
        problems = appcast.check_release(self.feed(), "1.0.1", 150, 1234)
        self.assertTrue(any("1234" in p for p in problems), problems)

    def test_version_and_url_must_match(self):
        root = self.feed()
        problems = appcast.check_release(root, "1.0.3", 150, 31457280)
        self.assertTrue(any("1.0.3" in p for p in problems), problems)
        self.assertTrue(any("Captylo-1.0.3.dmg" in p for p in problems), problems)

    def test_the_release_must_be_the_newest_item(self):
        problems = appcast.check_release(self.feed(), "1.0.0", 142, 31457280)
        self.assertTrue(any("newest" in p for p in problems), problems)


if __name__ == "__main__":
    unittest.main()
