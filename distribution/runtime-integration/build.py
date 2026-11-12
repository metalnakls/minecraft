#!/usr/bin/env python3
"""Build launcher-owned game hooks using Java 25 and the installed game classpath."""
import argparse, os, subprocess, tempfile, zipfile
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--classpath',required=True);p.add_argument('--out',type=Path,required=True);a=p.parse_args()
r=Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix='launcher-integration-') as tmp:
 subprocess.run([str(Path(os.environ['JAVA_HOME'])/'bin/javac'),'--release','25','-proc:none','-cp',a.classpath,'-d',tmp,*map(str,(r/'src').rglob('*.java'))],check=True)
 a.out.parent.mkdir(parents=True,exist_ok=True)
 with zipfile.ZipFile(a.out,'w',zipfile.ZIP_DEFLATED) as z:
  for f in Path(tmp).rglob('*.class'):z.write(f,str(f.relative_to(tmp)))
  for n in ['fabric.mod.json','launcher-integration.mixins.json','LICENSE']:z.write(r/n,n)
print(a.out)
