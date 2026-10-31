#!/usr/bin/env python3
"""Render a hash-addressed Pages installer from existing release asset pins."""
import argparse
import hashlib
from pathlib import Path
import re

here = Path(__file__).resolve().parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('release_directory', type=Path)
args = parser.parse_args()
script = (here/'install.template.sh').read_text()
for name in ('downloads.tsv', 'runtime-links.tsv', 'settings.tar.gz', 'Minecraft-arm64.zip'):
    digest = hashlib.sha256((args.release_directory/name).read_bytes()).hexdigest()
    script = script.replace('@'+name+'@', digest)
digest = hashlib.sha256(script.encode()).hexdigest()
docs = here.parent/'docs'
(docs/'installers').mkdir(exist_ok=True)
(docs/'installers'/f'{digest}.sh').write_text(script)
bootstrap = (docs/'install.sh').read_text()
bootstrap, replacements = re.subn(r"'https://[^']+'(?= -o)", f"'https://metalnakls.github.io/minecraft/installers/{digest}.sh'", bootstrap)
assert replacements == 1
bootstrap, replacements = re.subn(r"'[0-9a-f]{64}'", f"'{digest}'", bootstrap)
assert replacements == 1
(docs/'install.sh').write_text(bootstrap)
print(digest)
