#!/usr/bin/env python3
"""Verifies the generated Sparkle appcast before it is published.

The app ships with SURequireSignedFeed and SUVerifyUpdateBeforeExtraction, so a
feed that is unsigned, points at the wrong version, or lacks an enclosure
signature would make every existing install fail its next update. This check
turns that into a build-time error instead of a field report.
"""

import sys
import xml.etree.ElementTree as ET

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
NS = {"sparkle": SPARKLE_NS}


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: verify-appcast.py <appcast.xml> <version>", file=sys.stderr)
        return 2

    path, version = sys.argv[1], sys.argv[2]
    text = open(path, encoding="utf-8").read()

    if "sparkle-signatures:" not in text or "edSignature:" not in text:
        print("❌ feed is not signed but the app requires a signed feed", file=sys.stderr)
        return 1

    # generate_appcast appends the feed signature as a trailing comment.
    body = text.split("<!-- sparkle-signatures:")[0]
    try:
        root = ET.fromstring(body)
    except ET.ParseError as error:
        print(f"❌ appcast is not valid XML: {error}", file=sys.stderr)
        return 1

    items = root.findall("./channel/item")
    if not items:
        print("❌ appcast has no items", file=sys.stderr)
        return 1

    latest = next(
        (item for item in items if item.findtext("sparkle:version", namespaces=NS) == version),
        None,
    )
    if latest is None:
        found = [item.findtext("sparkle:version", namespaces=NS) for item in items]
        print(f"❌ appcast has no item for {version!r}; found {found}", file=sys.stderr)
        return 1

    enclosure = latest.find("enclosure")
    if enclosure is None:
        print("❌ appcast item has no enclosure", file=sys.stderr)
        return 1
    if not enclosure.get("{%s}edSignature" % SPARKLE_NS):
        print("❌ enclosure is missing its EdDSA signature", file=sys.stderr)
        return 1
    if not latest.findtext("sparkle:shortVersionString", namespaces=NS):
        print("❌ item is missing sparkle:shortVersionString", file=sys.stderr)
        return 1

    url = enclosure.get("url", "")
    if not url.endswith(f"/NewsBar-{version}.dmg"):
        print(f"❌ unexpected enclosure URL: {url}", file=sys.stderr)
        return 1

    print(f"   appcast OK: v{version}, {len(items)} item(s), signed feed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
