#!/usr/bin/env python3
"""Prepare a local, pinned release kit. Does not publish or alter a launcher."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import zipfile

HERE = Path(__file__).resolve().parent

def digest(path, algorithm='sha256'):
    return hashlib.file_digest(path.open('rb'), algorithm).hexdigest()

def package_settings(settings, out):
    with tarfile.open(out/'settings.tar.gz', 'w:gz') as tar:
        tar.add(settings/'game', arcname='game', filter=lambda i: None if i.name.endswith('.DS_Store') else i)
    with tarfile.open(out/'settings.tar.gz') as tar:
        forbidden = {'saves', 'screenshots', 'logs', 'crash-reports', 'usercache.json', 'servers.dat', 'XaeroWorldMap', 'XaeroWaypoints'}
        assert not any(forbidden.intersection(Path(n).parts) for n in tar.getnames()), 'Private game data in archive'

def render_installer(out):
    pins = {name:digest(out/name) for name in ('downloads.tsv','runtime-links.tsv','settings.tar.gz','Minecraft-arm64.zip')}
    script = (HERE/'install.template.sh').read_text()
    for name, sha in pins.items():
        script = script.replace('@'+name+'@', sha)
    (out/'install.sh').write_text(script)
    (out/'install.sh').chmod(0o755)
    (out/'SHA256SUMS').write_text(''.join(digest(p)+'  '+p.name+'\n' for p in sorted(out.iterdir()) if p.is_file() and p.name != 'SHA256SUMS'))

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--java-manifest', type=Path, required=True)
    ap.add_argument('--app', type=Path, default=Path('/Applications/Games/Minecraft.app'))
    ap.add_argument('--minecraft-root', type=Path, default=Path.home()/'Library/Application Support/minecraft')
    ap.add_argument('--shader-jar', type=Path, help='Use a reproducible shader build instead of the live instance JAR')
    ap.add_argument('--shader-url', help='Pinned shader fork release URL; omitted for local candidate checks')
    ap.add_argument('--bundled-mod', action='append', default=[], help='Explicit local mod artifact to mirror with its license notices')
    ap.add_argument('--require-resolved', action='store_true', help='Reject unresolved Modrinth lookups before a release')
    ap.add_argument('--settings-only', action='store_true', help='Refresh settings while preserving all pinned binaries and version metadata')
    args = ap.parse_args()
    ROOT = args.minecraft_root.resolve()
    PROFILE = ROOT/'home/Fabric 26.3'
    out = HERE / 'release'
    out.mkdir(exist_ok=True)
    staging = HERE / 'staging'
    if staging.exists():
        shutil.rmtree(staging)
    settings = staging / 'settings'
    target = settings / 'game/home/Fabric 26.3'
    target.mkdir(parents=True)
    rows = []
    inventory = []
    notices = []
    resolved_file = HERE/'resolved-mods.json'
    resolved = json.loads(resolved_file.read_text()) if resolved_file.exists() else {}
    def add(path, url, sha, algorithm='256', mode='644'):
        assert '\t' not in str(path) and '\n' not in str(path)
        rows.append((algorithm, sha, mode, str(path), url))

    # Only files actually used by this profile; no accounts, worlds, maps or logs.
    for src in sorted((PROFILE / 'config').rglob('*')):
        if not src.is_file() or src.is_symlink():
            continue
        rel = src.relative_to(PROFILE)
        if any(x.startswith('.') for x in rel.parts) or any(x in src.name for x in ('.bak', '.backup', 'fingerprint', 'patreon')):
            continue
        # Controller identity/calibration belongs to the receiving Mac.
        if 'controlify' in rel.parts or src.suffix not in ('.json', '.json5', '.toml', '.properties', '.txt', '.cfg', '.yaml'):
            continue
        data = src.read_text()
        if '/Users/' in data or re.search(r'(?i)(accessToken|refreshToken|password)\s*[=:]', data):
            raise ValueError(f'Manual sanitization required: {rel}')
        dest = target / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(data)
    shutil.copy2(PROFILE / 'options.txt', target / 'options.txt')
    skin_target = target/'CustomSkinLoader'
    skin_target.mkdir()
    shutil.copy2(PROFILE/'CustomSkinLoader/CustomSkinLoader.json', skin_target/'CustomSkinLoader.json')
    for kind in ('skins', 'capes', 'elytras'):
        dest = skin_target/'LocalSkin'/kind
        dest.mkdir(parents=True)
        for src in (PROFILE/'CustomSkinLoader/LocalSkin'/kind).glob('*.png'):
            if src.is_file() and not src.is_symlink() and re.fullmatch(r'[A-Za-z0-9_]{3,16}\.png', src.name):
                shutil.copy2(src, dest/src.name)
    # The active options have no enabled resource packs. Do not redistribute unused packs.
    options = (target / 'options.txt').read_text()
    if not re.search(r'^resourcePacks:\[\]$', options, re.M):
        raise ValueError('Enabled resource packs need explicit source URLs before packaging')

    if args.settings_only:
        # Version metadata must continue matching the existing download lock.
        with tarfile.open(out/'settings.tar.gz') as old:
            for member in old.getmembers():
                if member.isfile() and member.name.startswith('game/versions/'):
                    rel = Path(member.name)
                    if '..' in rel.parts:
                        raise ValueError('Unsafe version metadata path')
                    dest = settings/rel
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    dest.write_bytes(old.extractfile(member).read())
        package_settings(settings, out)
        render_installer(out)
        print('Updated current settings; pinned binaries and version metadata preserved. No saves copied.')
        return

    version_path = ROOT / 'versions/Fabric 26.3/Fabric 26.3.json'
    version = json.loads(version_path.read_text())
    # Optional Legacy Launcher translation helper has no upstream artifact URL.
    version['libraries'] = [x for x in version['libraries'] if not x['name'].startswith('ru.legacylauncher:fabric-loader-l10n:')]
    dest = settings / 'game/versions/Fabric 26.3/Fabric 26.3.json'
    dest.parent.mkdir(parents=True)
    dest.write_text(json.dumps(version, indent=2) + '\n')
    client = version['downloads']['client']
    add('game/versions/Fabric 26.3/Fabric 26.3.jar', client['url'], client['sha1'], '1')
    for lib in version['libraries']:
        allowed = not lib.get('rules')
        for rule in lib.get('rules', []):
            os = rule.get('os', {})
            if os.get('name', 'osx') == 'osx' and os.get('arch', 'aarch64') in ('aarch64', 'arm64'):
                allowed = rule['action'] == 'allow'
        if not allowed:
            continue
        parts = lib['name'].split(':')
        group, artifact, ver = parts[:3]
        rel = '/'.join((group.replace('.', '/'), artifact, ver, artifact+'-'+ver+('-'+parts[3] if len(parts)>3 else '')+'.jar'))
        entry = lib.get('downloads', {}).get('artifact', {})
        url = entry.get('url') or lib['url'].rstrip('/')+'/'+rel
        if entry.get('sha1'):
            add('game/libraries/'+rel, url, entry['sha1'], '1')
        else:
            add('game/libraries/'+rel, url, digest(ROOT/'libraries'/rel))
    index = version['assetIndex']
    add('game/assets/indexes/'+index['id']+'.json', index['url'], index['sha1'], '1')
    assets = json.loads((ROOT/'assets/indexes'/ (index['id']+'.json')).read_text())
    for h in sorted({x['hash'] for x in assets['objects'].values()}):
        add('game/assets/objects/'+h[:2]+'/'+h, 'https://resources.download.minecraft.net/'+h[:2]+'/'+h, h, '1')

    runtime = json.loads(args.java_manifest.read_text())
    links = []
    for name, entry in runtime['files'].items():
        path = 'runtime/'+name
        if entry['type'] == 'file':
            raw = entry['downloads']['raw']
            add(path, raw['url'], raw['sha1'], '1', '755' if entry.get('executable') else '644')
        elif entry['type'] == 'link':
            links.append((path, entry['target']))
    (out/'runtime-links.tsv').write_text(''.join('\t'.join(x)+'\n' for x in links))

    for src in sorted((PROFILE/'mods').glob('*.jar')):
        destination_name = src.name
        if src.name.startswith('metal-shaders-') and args.shader_jar:
            src = args.shader_jar
        with zipfile.ZipFile(src) as jar:
            meta = json.loads(jar.read('fabric.mod.json'))
        sha = digest(src)
        if meta['id'] == 'customskinloader-bootstrap':
            url = 'https://github.com/xfl03/MCCustomSkinLoader/releases/download/v15.1/'+src.name
        elif destination_name.startswith('metal-shaders-'):
            shutil.copy2(src, out/destination_name)
            url = args.shader_url or '@RELEASE@/'+destination_name
        elif destination_name in args.bundled_mod:
            with zipfile.ZipFile(src) as jar:
                license_files=[n for n in jar.namelist() if 'license' in n.lower() and not n.endswith('/')]
                if not license_files:
                    raise ValueError(f'No redistribution notices found for {destination_name}')
                notices.append(destination_name+'\n'+'\n'.join(jar.read(n).decode('utf-8') for n in license_files))
            shutil.copy2(src, out/destination_name)
            url='@RELEASE@/'+destination_name
        else:
            # Resolve the exact installed bytes, never a similarly named/latest version.
            url = resolved.get(sha) or 'modrinth:'+digest(src, 'sha512')
            if args.require_resolved and url.startswith('modrinth:'):
                raise ValueError(f'Unresolved upstream download: {destination_name}')
        add('game/home/Fabric 26.3/mods/'+destination_name, url, sha)
        inventory.append({'file':destination_name, 'version':meta.get('version'), 'license':meta.get('license'),
                          'sha256':sha, 'source':url, 'contact':meta.get('contact', {})})
    (out/'mod-inventory.json').write_text(json.dumps(inventory, indent=2)+'\n')
    (out/'THIRD-PARTY-NOTICES.txt').write_text('\n\n'.join(notices)+'\n')
    (out/'downloads.tsv').write_text(''.join('\t'.join(x)+'\n' for x in rows))
    package_settings(settings, out)
    subprocess.run(['/usr/bin/ditto','-c','-k','--sequesterRsrc','--keepParent',str(args.app),str(out/'Minecraft-arm64.zip')], check=True)
    render_installer(out)
    print(f'Prepared {len(rows)} pinned downloads; {len(inventory)} mods in {out}')
    print('Nothing published. Modrinth hash lookups must pass before release; sign/notarize the app and rerun preparation.')

if __name__ == '__main__':
    main()
