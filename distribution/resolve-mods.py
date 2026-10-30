#!/usr/bin/env python3
"""Resolve exact Modrinth hashes ahead of publication; curl uses native networking."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import concurrent.futures
import argparse

HERE = Path(__file__).resolve().parent

def resolve(item, metadata):
    if not item['source'].startswith('modrinth:'):
        return item['sha256'], item['source']
    sha512 = item['source'].split(':', 1)[1]
    with tempfile.TemporaryDirectory() as tmp:
        data = metadata[sha512]
        entry = next(f for f in data['files'] if f['hashes']['sha512'] == sha512)
        jar = Path(tmp)/'mod.jar'
        subprocess.run(['curl','--fail','--location','--silent','--show-error','--retry','4','--retry-all-errors','--retry-max-time','90','--connect-timeout','10',
                        '--max-time','120',entry['url'],'-o',str(jar)],check=True)
        assert hashlib.file_digest(jar.open('rb'),'sha256').hexdigest() == item['sha256']
    print('Verified:', item['file'], flush=True)
    return item['sha256'], entry['url']

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--metadata', type=Path, help='Previously fetched Modrinth version_files response')
    args = parser.parse_args()
    items = json.loads((HERE/'release/mod-inventory.json').read_text())
    output = HERE/'resolved-mods.json'
    result = json.loads(output.read_text()) if output.exists() else {}
    failures = []
    pending = [item for item in items if item['sha256'] not in result]
    hashes = [item['source'].split(':',1)[1] for item in pending if item['source'].startswith('modrinth:')]
    metadata = {}
    if hashes:
        if args.metadata:
            metadata = json.loads(args.metadata.read_text())
        else:
            with tempfile.TemporaryDirectory() as tmp:
                request = Path(tmp)/'request.json'
                response = Path(tmp)/'response.json'
                request.write_text(json.dumps({'hashes': hashes, 'algorithm':'sha512'}))
                subprocess.run(['curl','--fail','--location','--silent','--show-error','--retry','4',
                                '--retry-all-errors','--retry-max-time','90','--connect-timeout','10','--max-time','30',
                                '-H','Content-Type: application/json','--data-binary','@'+str(request),
                                'https://api.modrinth.com/v2/version_files','-o',str(response)],check=True)
                metadata=json.loads(response.read_text())
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        tasks = {pool.submit(resolve, item, metadata): item for item in pending}
        for task in concurrent.futures.as_completed(tasks):
            item = tasks[task]
            try:
                sha, url = task.result()
                result[sha] = url
                output.write_text(json.dumps(result, indent=2)+'\n')
            except Exception as error:
                failures.append(item['file'])
                print('FAILED:', item['file'], type(error).__name__, flush=True)
    (HERE/'resolved-mods.json').write_text(json.dumps(result, indent=2)+'\n')
    if failures:
        raise SystemExit(f'{len(failures)} mods unresolved; verified results retained for retry: {failures}')
    print('All upstream downloads verified. Rerun prepare.py to embed direct URLs.')
