#!/usr/bin/env python3
"""Sign a launcher ZIP and generate the fork's Sparkle feed locally. Never publishes."""
import argparse
import plistlib
import subprocess
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('archive', type=Path)
parser.add_argument('sign_update', type=Path)
args = parser.parse_args()
with zipfile.ZipFile(args.archive) as archive:
    info = plistlib.loads(archive.read('Minecraft.app/Contents/Info.plist'))
version = info['CFBundleShortVersionString']
assert info['SUFeedURL'] == 'https://metalnakls.github.io/minecraft/appcast.xml'
sign = [str(args.sign_update.resolve()), '--account', 'metalnakls.minecraft']
signature = subprocess.check_output(sign + ['-p', str(args.archive.resolve())], text=True).strip()
subprocess.run(sign + ['--verify', str(args.archive.resolve()), signature], check=True)
ns = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', ns)
rss = ET.Element('rss', version='2.0')
channel = ET.SubElement(rss, 'channel')
ET.SubElement(channel, 'title').text = 'Minecraft launcher updates'
item = ET.SubElement(channel, 'item')
ET.SubElement(item, 'title').text = version
ET.SubElement(item, f'{{{ns}}}version').text = info['CFBundleVersion']
ET.SubElement(item, f'{{{ns}}}shortVersionString').text = version
ET.SubElement(item, f'{{{ns}}}minimumSystemVersion').text = info['LSMinimumSystemVersion']
ET.SubElement(item, 'description').text = 'Launcher updates from this fork, with dynamic icon preservation.'
ET.SubElement(item, 'enclosure', {
    'url': f'https://github.com/metalnakls/minecraft/releases/download/{version}/Minecraft-arm64.zip',
    'type': 'application/octet-stream',
    'length': str(args.archive.stat().st_size),
    f'{{{ns}}}edSignature': signature,
})
ET.indent(rss)
feed = Path(__file__).resolve().parent.parent / 'docs/appcast.xml'
ET.ElementTree(rss).write(feed, encoding='utf-8', xml_declaration=True)
print(f'Verified update signature and wrote {feed}')
