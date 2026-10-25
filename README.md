# Whisper PTT

Local push-to-talk dictation for Linux and GNOME. Hold **Right Ctrl**, speak, and release to type into the focused application. Audio is transcribed with faster-whisper on an NVIDIA GPU; optional local Ollama cleanup turns rambling speech into readable writing while aiming to preserve your meaning and voice.

## Desktop controls

Open GNOME's top-right system menu:

| Button | What it does |
| --- | --- |
| **Whisper** | Turns dictation and cleanup on together. Off stops dictation, disables cleanup, and requests unloading the cleanup model. |
| **Cleanup** | Enables rewriting or types as spoken while dictation remains running. Off requests unloading the cleanup model. Disabled while Whisper is off. |

Stopping dictation also stops the optional Mac transcription server. These controls do not change the service's login preference. GPU memory used by other applications is unaffected. The indicator reflects the service state, not whether the microphone and GPU have finished initializing.

Text is inserted using a virtual keyboard, without touching the Linux clipboard. A US keyboard layout is assumed; unsupported characters are normalized. The trigger is read through Linux input devices, including on Wayland.

## Requirements

- Linux, Python 3.11+, systemd user services, PipeWire or another PortAudio-compatible microphone source.
- NVIDIA GPU and compatible driver/CUDA libraries for the default transcription configuration. CPU transcription is configurable.
- Ollama for optional cleanup. The example uses `qwen3.5:9b`; allow space for both Whisper and the cleanup model in GPU memory. Larger models may prevent transcription from loading.
- GNOME Shell 50 for the included extension (other versions have not been validated).
- System commands: `notify-send`, `nvidia-smi` for GPU status; Tailscale for optional network dictation.

## Install

Keep the checkout at `~/.local/share/whisper-ptt`; the command wrapper and extension helper expect that location. If you already have an installation there, back it up or update its Git remote rather than cloning over it.

```bash
git clone https://github.com/YOUR-USERNAME/whisper-ptt.git ~/.local/share/whisper-ptt
cd ~/.local/share/whisper-ptt
python3 -m venv venv
venv/bin/pip install -r requirements.txt
ollama pull qwen3.5:9b
bash install-links.sh
```

Install your distribution's PortAudio runtime first if sounddevice cannot open audio. Ensure Ollama is running before using cleanup. The requirements file includes CUDA 12 libraries used by CTranslate2; a compatible NVIDIA driver is still required.

The service needs permission to read keyboard events and write `/dev/uinput`. Review the supplied rule before installing it; it grants the active local session access to input events:

```bash
sudo cp udev/70-whisper-ptt-input.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules
sudo modprobe uinput
```

Your distribution may require additional permissions for `/dev/uinput`; do not make input devices world-writable. Log out and back in to refresh device permissions. Then:

```bash
systemctl --user enable --now whisper-ptt.service
gnome-extensions enable whisper-polish@felixfalling
```

Log out and back in after installing or changing the extension JavaScript. No third-party microphone permissions or GPU benchmarks have been validated by the automated control tests.

## Configure

Edit `~/.config/whisper-ptt/config.json`, then run `whisper-ptt restart`. Start with `config.example.json`; it contains no credentials and disables network dictation.

- `model`, `device`, `compute_type`: Whisper transcription settings.
- `polish_model`: local Ollama model for cleanup.
- `polish_prompt`: editing style. The example removes filler and repetition and preserves substantive details, questions, uncertainty, and the speaker's tone.
- `transcribe_while_talking: false`: waits for the complete recording before editing, giving cleanup the full context. Turn it on for sentence-by-sentence processing with lower latency.
- `polish_min_word_similarity`: low word overlap triggers an extra local meaning check. This model-based check can still miss meaning changes. Failed cleanup falls back to the transcript.
- `polish_timeout`: maximum wait per cleanup request; large rewrites can require two requests.
- `idle_unload_seconds`: parks Whisper in system RAM after inactivity, releasing its GPU allocation.
- `type_delay_ms`: typing pace; increase if an application drops characters.

Turning cleanup on may warm its model. Turning it off through the UI explicitly requests unloading it; the original CLI's polish-off command only changes the preference. Models and transcripts stay local unless you explicitly configure a remote Ollama address or enable the network server. The service journal includes dictated text and can include rejected cleanup drafts; keep logs private.

## Commands

```bash
whisper-ptt status
whisper-ptt logs 30
whisper-ptt restart
whisper-ptt polish on
whisper-ptt polish off
whisper-ptt off
whisper-ptt disable  # also disable startup at login
python3 ~/.local/share/whisper-ptt/bin/whisper-ui.py all off
python3 ~/.local/share/whisper-ptt/bin/whisper-ui.py all on
```

## Optional Mac client

See [mac/README.md](mac/README.md). Set a randomly generated server token and enable the desktop's Tailscale-bound server, then run `bash mac/package.sh`. The generated archive includes the token: share it privately and never commit it. The Mac client uses clipboard insertion, unlike the Linux virtual keyboard.

## Development

```bash
python3 -m unittest discover -s tests -p test_controls.py -v
venv/bin/python -m unittest discover -s tests -v
```

Control tests mock systemd and Ollama. The full suite requires dependencies and supports optional real virtual-keyboard tests; socket-dependent tests need permission to bind local sockets. A passing automated suite does not validate a running GNOME session, transcription accuracy, or cleanup quality.

Work in this checkout and commit changes before deploying:

```bash
git switch -c improve-cleanup
# Edit, test, then review:
git diff
git add README.md whisper-ptt.py  # choose the files you changed
git commit -m "Improve cleanup behavior"
git push -u origin improve-cleanup
```

Use `git log --oneline` to inspect history and `git revert <commit>` to undo a committed change. Restart dictation after daemon changes; log out and back in after extension changes. Do not run `install-links.sh` from a second checkout unless you intend to point your installation at it.

## Public repository contents

Only source, tests, and example configuration belong here. Runtime configurations, tokens, environments, model downloads, logs, recordings, generated Mac archives, and private before/after dictation collections are excluded. This public repository begins with a curated snapshot; the original local repository retains its earlier history.

## Canonical checkout

For this installation, the maintained checkout is `~/.local/share/whisper-ptt`. Its `.git` directory, service, virtual environment, and source live together. Any development alias must be a symlink to this directory, rather than a second clone. Runtime configuration remains under `~/.config/whisper-ptt` and is never committed.

For experiments, use a branch in the canonical checkout. An experimental worktree can be used for tests, but run `install-links.sh` only from the canonical checkout. Restart the service to load daemon changes.
