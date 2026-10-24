#!/usr/bin/env python3
"""Desktop controls for dictation and its local cleanup model."""
import json
from pathlib import Path
import subprocess
import sys
import urllib.error
import urllib.request

HOME=Path.home()
UNIT='whisper-ptt.service'
STATE=HOME/'.local/state/whisper-ptt/polish'
CLI=HOME/'.local/bin/whisper-ptt'
CONFIG=HOME/'.config/whisper-ptt/config.json'
def active():
    return subprocess.run(['systemctl','--user','is-active','--quiet',UNIT],timeout=10).returncode==0
def unload():
    cfg=json.loads(CONFIG.read_text())
    req=urllib.request.Request(cfg.get('ollama_url','http://127.0.0.1:11434').rstrip('/')+'/api/generate',
        data=json.dumps({'model':cfg.get('polish_model','qwen3:14b'),'keep_alive':0}).encode(),
        headers={'Content-Type':'application/json'})
    try:
        with urllib.request.urlopen(req,timeout=20) as response:
            response.read()
    except urllib.error.URLError as exc:
        raise RuntimeError('Dictation setting changed, but cleanup model could not be unloaded: '+str(exc)) from exc

def main():
    args=sys.argv[1:]
    if args==['status']:
        cfg=json.loads(CONFIG.read_text())
        polish=STATE.read_text().strip()=='on' if STATE.exists() else cfg.get('polish',True)
        print(json.dumps({'active':active(),'polish':polish}))
    elif args in (['all','on'],['all','off']):
        on=args[1]=='on'
        if not on:
            # Stop first: Right Ctrl must no longer trigger recordings during unload.
            subprocess.run(['systemctl','--user','stop',UNIT],check=True,timeout=60)
        STATE.parent.mkdir(parents=True,exist_ok=True)
        STATE.write_text(args[1]+'\n')
        if on:
            subprocess.run(['systemctl','--user','start',UNIT],check=True,timeout=60)
            subprocess.run([str(CLI),'polish','on','--quiet'],check=True,timeout=10)
        else:
            unload()
    elif args in (['dictation','on'],['dictation','off']):
        on=args[1]=='on'
        subprocess.run(['systemctl','--user','start' if on else 'stop',UNIT],check=True,timeout=60)
        if not on: unload()
    elif args in (['polish','on'],['polish','off']):
        on=args[1]=='on'
        # Persist the preference without warming a model while dictation is stopped.
        STATE.parent.mkdir(parents=True,exist_ok=True)
        STATE.write_text(args[1]+'\n')
        if on and active():
            subprocess.run([str(CLI),'polish','on','--quiet'],check=True,timeout=10)
        elif not on: unload()
    else:
        raise SystemExit('Usage: whisper-ui.py status | all on|off | dictation on|off | polish on|off')
if __name__=='__main__':
    try: main()
    except Exception as exc:
        print(str(exc),file=sys.stderr)
        sys.exit(1)
