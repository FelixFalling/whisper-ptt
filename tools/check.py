"""Parse tracked Python/JSON files without importing hardware dependencies."""
import ast
import json
from pathlib import Path
import subprocess

root=Path(__file__).resolve().parent.parent
files=subprocess.check_output(['git','-C',str(root),'ls-files','--cached','--others','--exclude-standard','-z']).decode().split('\0')
count=0
for relative in filter(None,files):
    path=root/relative
    if not path.is_file(): continue
    if path.suffix=='.py':
        ast.parse(path.read_text(),filename=relative)
        count+=1
    elif path.suffix=='.json':
        json.loads(path.read_text())
        count+=1
print(f'Syntax checked {count} Python/JSON files.')
