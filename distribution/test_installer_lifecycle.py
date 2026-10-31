#!/usr/bin/env python3
"""Run the actual installer with fixture paths and the real published app archive."""
import argparse
import hashlib
import os
import signal
import time
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import zipfile

HERE=Path(__file__).resolve().parent
ap=argparse.ArgumentParser(); ap.add_argument('launcher_zip', type=Path); args=ap.parse_args()
def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def put(path, data): path.parent.mkdir(parents=True, exist_ok=True); path.write_text(data)
with tempfile.TemporaryDirectory(prefix='minecraft-lifecycle-') as directory:
    root=Path(directory).resolve(); release=root/'release'; release.mkdir()
    game=root/'game'; base=root/'cache'; support=root/'support'; applications=root/'apps'; backups=root/'backups'
    profile=game/'home/Fabric 26.3'
    put(profile/'options.txt','personal settings')
    put(profile/'saves/world/level.dat','personal world')
    put(profile/'accounts.json','personal account')
    put(game/'libraries/test.jar','matching library')
    fixtures=release/'payloads'; fixtures.mkdir()
    rows=[]
    def payload(name, path, contents, mode='644'):
        source=fixtures/name; source.write_bytes(contents)
        rows.append('\t'.join(('256',sha(source),mode,path,str(source))))
    payload('library','game/libraries/test.jar',b'matching library')
    payload('java','runtime/jre.bundle/Contents/Home/bin/java',b'#!/bin/sh\necho "fixture Java" >&2\n','755')
    mod=fixtures/'mod.jar'
    with zipfile.ZipFile(mod,'w') as z: z.writestr('fabric.mod.json','{"id":"fixture","version":"1.0.0"}')
    rows.append('\t'.join(('256',sha(mod),'644','game/home/Fabric 26.3/mods/fixture.jar',str(mod))))
    (release/'downloads.tsv').write_text('\n'.join(rows)+'\n')
    (release/'runtime-links.tsv').write_text('runtime/java\tjre.bundle/Contents/Home/bin/java\n')
    settings=root/'settings'; put(settings/'game/home/Fabric 26.3/options.txt','template settings')
    put(settings/'game/home/Fabric 26.3/shared-launch-settings.json','{"schema":1,"jvmArguments":"-XX:+UseZGC","xms":1024,"xmx":8192}')
    put(profile/'.shared-launch-settings.applied','old settings marker')
    with tarfile.open(release/'settings.tar.gz','w:gz') as tar: tar.add(settings/'game',arcname='game')
    shutil.copy2(args.launcher_zip,release/'Minecraft-arm64.zip')
    # Simulate Lisa's previous successful downloads in the older random stage layout.
    old_stage=base/'stage.previous'; old_stage.mkdir(parents=True)
    for name in ('downloads.tsv','runtime-links.tsv','settings.tar.gz','Minecraft-arm64.zip'): shutil.copy2(release/name,old_stage/name)
    script=(HERE/'install.template.sh').read_text()
    for name in ('downloads.tsv','runtime-links.tsv','settings.tar.gz','Minecraft-arm64.zip'):
        script=script.replace('@'+name+'@',sha(release/name))
    # Redirect only filesystem/configuration inputs; HOME and installer logic stay intact.
    redirects={
        '$HOME/Library/Application Support/minecraft':str(game),
        '$HOME/Library/Application Support/tsmc.minecraft':str(support),
        '$HOME/Library/Application Support/Minecraft-Setup/backups':str(backups),
        '$HOME/Library/Caches/Minecraft-Setup':str(base),
        '$HOME/Applications':str(applications),
        '/Applications/Games/Minecraft.app':str(root/'global-games/Minecraft.app'),
        '/Applications/Minecraft.app':str(root/'global/Minecraft.app'),
        '/usr/bin/defaults read tsmc.minecraft launcherWorkingDirectory':"printf ''",
    }
    for before,after in redirects.items():
        assert before in script, before
        script=script.replace(before,after)
    installer=root/'install.sh'; installer.write_text(script)
    command=['/bin/bash',str(installer),'--local-release',str(release),'--allow-adhoc']
    for iteration in range(3):
        if iteration==2: (game/'libraries/test.jar').write_text('damaged')
        result=subprocess.run(command,capture_output=True,text=True,timeout=45)
        assert result.returncode==0,result.stdout+result.stderr
        assert 'Progress: 3/3 files' in result.stdout,result.stdout
        assert (game/'libraries/test.jar').read_text()=='matching library'
        assert (profile/'options.txt').read_text()=='template settings'
        assert (profile/'saves/world/level.dat').read_text()=='personal world'
        assert (profile/'accounts.json').read_text()=='personal account'
        assert not (base/'setup.lock').exists()
        assert not (profile/'.shared-launch-settings.applied').exists()
        assert '-XX:+UseZGC' in (profile/'shared-launch-settings.json').read_text()
        assert len(list(base.glob('stage-*')))==1
        if iteration==0: assert 'Reusing previous download: Minecraft-arm64.zip' in result.stdout
        if iteration==1: assert '3 reused from installation' in result.stdout and '0 downloaded' in result.stdout
    print('PASS full installer: real app signature, old downloads imported, repeat uses 3/3 installed files, repair despite receipt, player data preserved, lock released')
    # Inject a pause only to send a real terminal-style Ctrl-C to the process group.
    paused_script = script.replace("printf 'Verifying launcher signature and Java", "printf 'INTERRUPT-READY\\n'\nsleep 30\nprintf 'Verifying launcher signature and Java")
    assert paused_script != script
    paused_installer=root/'paused.sh'; paused_installer.write_text(paused_script)
    log=root/'interrupt.log'
    with log.open('w') as output:
        process=subprocess.Popen(['/bin/bash',str(paused_installer),'--local-release',str(release),'--allow-adhoc'],
                                 stdout=output,stderr=subprocess.STDOUT,start_new_session=True)
        try:
            deadline=time.monotonic()+20
            while 'INTERRUPT-READY' not in log.read_text():
                assert process.poll() is None, log.read_text()
                assert time.monotonic()<deadline, log.read_text()
                time.sleep(.1)
            concurrent=subprocess.run(command,capture_output=True,text=True,timeout=10)
            assert concurrent.returncode!=0 and 'Another setup is running' in concurrent.stderr
            os.killpg(process.pid,signal.SIGINT)
            assert process.wait(timeout=5)==130, log.read_text()
            assert not (base/'setup.lock').exists()
            assert 'Rerun the same command to resume' in log.read_text()
        finally:
            if process.poll() is None:
                os.killpg(process.pid,signal.SIGKILL); process.wait()
    resumed=subprocess.run(command,capture_output=True,text=True,timeout=45)
    assert resumed.returncode==0,resumed.stdout+resumed.stderr
    assert '3 reused from installation' in resumed.stdout and '0 downloaded' in resumed.stdout
    print('PASS concurrent run blocked; Ctrl-C cleans up lock; same command resumes using verified files')
    # Exercise the exact verifier repeatedly with the real signed app.
    library=root/'functions.sh'; library.write_text(script.split('if [[ "${1:-}" == --fetch-row ]]')[0])
    app=applications/'Minecraft.app'
    result=subprocess.run(['/bin/bash','-c','source "$1"; for n in {1..50}; do verify_app "$2" true; done','test',str(library),str(app)],capture_output=True,text=True)
    assert result.returncode==0,result.stderr
    # Corrupt a sealed file: signature verification must continue to reject it.
    executable=app/'Contents/MacOS/Minecraft'
    with executable.open('ab') as file: file.write(b'tampered')
    result=subprocess.run(['/bin/bash','-c','source "$1"; verify_app "$2" true','test',str(library),str(app)],capture_output=True,text=True)
    assert result.returncode!=0,'Tampered app was accepted'
    print('PASS 50 real ad-hoc signature checks; tampered app rejected')
