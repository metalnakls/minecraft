#!/usr/bin/env python3
"""Exercise installer reuse against disposable profiles, never the live game."""
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import zipfile

HERE = Path(__file__).resolve().parent
TEMPLATE = (HERE / 'install.template.sh').read_text()

def jar(path, mod_id, version):
    path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(path, 'w') as archive:
        archive.writestr('fabric.mod.json', '{"id":"%s","version":"%s"}' % (mod_id, version))

def put(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(data)

with tempfile.TemporaryDirectory(prefix='minecraft-reuse-') as directory:
    root = Path(directory).resolve()
    game, stage, base = root/'game', root/'stage', root/'cache'
    profile = game/'home/Fabric 26.3'
    staged = stage/'game/home/Fabric 26.3'
    library = root/'functions.sh'
    library.write_text(TEMPLATE.split('if [[ "${1:-}" == --fetch-row ]]')[0])
    def run(commands, success=True):
        result = subprocess.run(['/bin/bash', '-c', 'source "$1"\ngame="$2"; stage="$3"; base="$4"; backup=""\n'+commands,
                                 'fixture', str(library), str(game), str(stage), str(base)], capture_output=True, text=True)
        assert (result.returncode == 0) == success, result.stdout + result.stderr
        return result

    for rel in ['options.txt', 'config/test.json', 'CustomSkinLoader/LocalSkin/skins/Lisa.png', 'saves/world/level.dat', 'accounts.json']:
        put(profile/rel, 'personal '+rel)
    put(staged/'options.txt', 'template settings')
    put(staged/'config/test.json', 'template config')
    put(staged/'config/new.json', 'new config')
    put(staged/'CustomSkinLoader/LocalSkin/skins/Lisa.png', 'template skin')
    put(game/'libraries/shared.jar', 'old library')
    put(stage/'game/libraries/shared.jar', 'new library')
    jar(profile/'mods/old-name.jar', 'cleanmenu', '0.0.1')
    jar(profile/'mods/unrelated.jar', 'unrelated', '1.0')
    jar(staged/'mods/mcui.jar', 'cleanmenu', '0.1.0')
    old_mod = (profile/'mods/old-name.jar').read_bytes()
    preserved = {p: p.read_bytes() for p in profile.rglob('*') if p.is_file() and 'mods' not in p.parts}
    run('merge_game')
    assert all(p.read_bytes() == value for p, value in preserved.items())
    assert (profile/'config/new.json').read_text() == 'new config'
    assert (profile/'mods/mcui.jar').exists() and not (profile/'mods/old-name.jar').exists()
    assert (profile/'mods/unrelated.jar').exists()
    backups = list((base/'backups').iterdir())
    assert len(backups) == 1
    assert (backups[0]/'game/home/Fabric 26.3/mods/old-name.jar').read_bytes() == old_mod
    assert (backups[0]/'game/libraries/shared.jar').read_text() == 'old library'
    run('merge_game')
    assert len(list((base/'backups').iterdir())) == 1, 'Identical rerun made another backup'
    # Different app/runtime is backed up; identical content is reused.
    put(stage/'runtime/bin/java', 'new java')
    put(root/'installed-runtime/bin/java', 'old java')
    run('replace_directory "$stage/runtime" "${game%/game}/installed-runtime" runtime')
    assert (root/'installed-runtime/bin/java').read_text() == 'new java'
    assert any((p/'runtime/bin/java').exists() and (p/'runtime/bin/java').read_text() == 'old java' for p in (base/'backups').iterdir())
    put(stage/'runtime/bin/java', 'new java')
    count = len(list((base/'backups').iterdir()))
    run('replace_directory "$stage/runtime" "${game%/game}/installed-runtime" runtime')
    assert len(list((base/'backups').iterdir())) == count
    # Download worker uses hash-matching installed bytes even with an unreachable URL.
    (root/'downloads').mkdir(); (root/'cache-files').mkdir()
    payload = (game/'libraries/shared.jar').read_bytes()
    row = '\t'.join(('256', hashlib.sha256(payload).hexdigest(), '644', 'game/libraries/shared.jar', 'https://invalid.invalid/no-download'))
    subprocess.run(['/bin/bash', str(HERE/'install.template.sh'), '--fetch-row', str(root), str(root/'cache-files'), str(root/'downloads'), row],
                   env=dict(os.environ, MC_SETUP_EXISTING_GAME=str(game)), check=True, timeout=10)
    assert (root/'downloads/game/libraries/shared.jar').read_bytes() == payload
    # Reject an existing symlink before changing any files.
    (profile/'config/test.json').unlink()
    (profile/'config/test.json').symlink_to(root/'outside')
    put(root/'outside', 'untouched')
    run('merge_game', success=False)
    assert (root/'outside').read_text() == 'untouched'
    # Same helper also handles a clean installation.
    fresh = root/'fresh'; fresh.mkdir()
    run('game="${game%/game}/fresh"; merge_game')
    assert (fresh/'home/Fabric 26.3/mods/mcui.jar').is_file()
    print('PASS: existing profile, settings/skins/saves/accounts preservation, backups, mod deduplication, repeat/fresh install, Java reuse, verified local downloads, symlink rejection')
