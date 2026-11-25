#!/usr/bin/env python3
import argparse
import os
from email.utils import formatdate
from xml.sax.saxutils import escape, quoteattr


def main():
    parser = argparse.ArgumentParser(description="Write the Sparkle appcast for one GoLens release.")
    parser.add_argument("--version", required=True, help="CFBundleShortVersionString, for example 2026.11.25")
    parser.add_argument("--build", required=True, help="CFBundleVersion of the release build")
    parser.add_argument("--dmg", required=True, help="the released disk image")
    parser.add_argument("--signature", required=True, help="file holding the base64 EdDSA signature of the disk image")
    parser.add_argument("--repo", required=True, help="owner/name of the repository that hosts the release")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    tag = f"v{args.version}"
    download = f"https://github.com/{args.repo}/releases/download/{tag}/{os.path.basename(args.dmg)}"
    notes = f"https://github.com/{args.repo}/releases/tag/{tag}"
    signature = open(args.signature).read().strip()
    length = os.path.getsize(args.dmg)

    xml = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>GoLens</title>
    <item>
      <title>{escape("GoLens " + args.version)}</title>
      <pubDate>{formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{escape(args.build)}</sparkle:version>
      <sparkle:shortVersionString>{escape(args.version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>{escape(notes)}</sparkle:fullReleaseNotesLink>
      <enclosure url={quoteattr(download)} length="{length}" type="application/octet-stream" sparkle:edSignature={quoteattr(signature)}/>
    </item>
  </channel>
</rss>
"""
    with open(args.output, "w") as f:
        f.write(xml)


if __name__ == "__main__":
    main()
