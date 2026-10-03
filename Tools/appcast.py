#!/usr/bin/env python3
"""Adds a release to appcast.xml (the feed Sparkle reads), newest first.

usage: appcast.py <version> <build> <dmg-url> <length> <ed-signature> <notes-file>
"""
import html, sys
from email.utils import formatdate

version, build, url, length, signature, notes_path = sys.argv[1:7]
notes = [line.strip() for line in open(notes_path) if line.strip()]
items = "".join(f"<li>{html.escape(n)}</li>" for n in notes) or "<li>Improvements and fixes.</li>"

item = f"""    <item>
      <title>Redraft {version}</title>
      <pubDate>{formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[<ul>{items}</ul>]]></description>
      <enclosure url="{html.escape(url)}" length="{length}" type="application/octet-stream" sparkle:edSignature="{signature}"/>
    </item>
"""

path = "appcast.xml"
text = open(path).read()
marker = "    <language>en</language>\n"
if marker not in text:
    sys.exit("appcast.xml: couldn't find where to add the release")
open(path, "w").write(text.replace(marker, marker + item, 1))
print(f"appcast.xml: added Redraft {version} (build {build})")
