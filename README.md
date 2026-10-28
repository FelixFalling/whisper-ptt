# Whisper PTT

Local push-to-talk dictation for Linux and GNOME. Hold **Right Ctrl**, speak, and release to type into the focused application. Audio is transcribed with faster-whisper on an NVIDIA GPU; optional local Ollama cleanup turns rambling speech into readable writing while aiming to preserve your meaning and voice.

A Mac can dictate through the same GPU: the **Whisper PTT** menu bar app sends its recordings to the desktop over Tailscale. See [Mac menu bar app](#mac-menu-bar-app).

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

Run `make config` to edit `~/.config/whisper-ptt/config.json`, then run `make deploy` to validate and restart. See [the settings guide](docs/configuration.md) for examples and the UI override behavior. Start with `config.example.json`; it contains no credentials and disables network dictation.

- `model`, `device`, `compute_type`: Whisper transcription settings.
- `polish_model`: local Ollama model for cleanup.
- `polish_prompt`: editing style. The example removes filler and repetition and preserves substantive details, questions, uncertainty, and the speaker's tone.
- `transcribe_while_talking: false`: waits for the complete recording before editing, giving cleanup the full context. Turn it on for sentence-by-sentence processing with lower latency.
- `polish_min_word_similarity`: low word overlap triggers an extra local meaning check. This model-based check can still miss meaning changes. Failed cleanup falls back to the transcript.
- `polish_timeout`: maximum wait per cleanup request; large rewrites can require two requests.
- `idle_unload_seconds`: parks Whisper in system RAM after inactivity, releasing its GPU allocation.
- `short_entry_min_words`: omit the terminal period below this word count (default `4`, `0` disables). Questions, exclamations, and ellipses are preserved.
- `type_delay_ms`: typing pace; increase if an application drops characters.

Turning cleanup on may warm its model. Turning it off through the UI explicitly requests unloading it; the original CLI's polish-off command only changes the preference. Models and transcripts stay local unless you explicitly configure a remote Ollama address or enable the network server. The service journal includes dictated text and can include rejected cleanup drafts; keep logs private.

## Commands

```bash
whisper-ptt status
whisper-ptt logs 30
whisper-ptt logs --follow  # readable live input/output blocks
whisper-ptt restart
whisper-ptt polish on
whisper-ptt polish off
whisper-ptt off
whisper-ptt disable  # also disable startup at login
python3 ~/.local/share/whisper-ptt/bin/whisper-ui.py all off
python3 ~/.local/share/whisper-ptt/bin/whisper-ui.py all on
```

Completed dictations now have separate **Raw input** and **Cleaned-up output**
sections in fenced text blocks, with paragraphs preserved. Cleanup failures and
disabled/skipped cleanup are explicitly labelled. Timing appears below the text.
This applies to new local, streaming, and remote dictations; older log entries
cannot recover raw input that was never saved. Use `whisper-ptt logs --follow`
or `journalctl --user -u whisper-ptt.service -f -o cat` to avoid repeating the
systemd prefix on every line. Press Ctrl+C to leave the viewer.

## Mac menu bar app

**Whisper PTT.app** brings the same dictation to a Mac. Hold **right Option**, speak, and release: the Mac records, the desktop transcribes on its GPU (and cleans up the text if you want), and the Mac pastes the result where the cursor is. When the desktop is off or unreachable, the Mac transcribes locally with a slower model and no cleanup.

Click the waveform in the Mac's menu bar:

| Control | What it does |
| --- | --- |
| **Whisper** | Turns dictation on the Mac on or off. Off, right Option is an ordinary key again. |
| **Cleanup** | Cleaned-up text, or your words as spoken. Applies only to the Mac's dictations; the desktop's own Cleanup switch is unaffected. |
| Desktop row | Whether the desktop answers; click to check again. |
| **Last dictation** | Click to copy it again. |
| **Open at Login** | Starts the app at login. |

The Mac cannot switch the desktop on. If Whisper is off at the desktop, the Mac uses its local fallback until you turn it back on there (`make start` or the GNOME Whisper button).

### Set up the desktop

In `~/.config/whisper-ptt/config.json`, set `"server": true` and a randomly generated `server_token`, then `make deploy`. The server listens only on this machine's Tailscale address, and every request must carry the token. Run `bash mac/package.sh` to build `whisper-ptt-mac.zip`, which holds the Mac's settings file with that token: share it privately and never commit it.

### Install on the Mac

1. On the Mac, with Tailscale running, unzip `whisper-ptt-mac.zip` and run `mac/install.sh` once. It writes `~/.config/whisper-ptt/mac.json` and installs the local fallback.
2. From the desktop, build the app on the Mac over SSH (the Mac needs the Xcode Command Line Tools, not Xcode):

   ```bash
   make mac-app MAC=<ssh host of the Mac>       # leaves Whisper-PTT.dmg in the Mac's Downloads
   make mac-install MAC=<ssh host of the Mac>   # or: install into Applications and open it
   ```

3. Open the .dmg, drag **Whisper PTT** to **Applications**, and open it. A welcome window asks for Microphone, Accessibility, and Input Monitoring, ticking each as it is allowed.

The Mac pastes through the clipboard and then restores what was on it, unlike the Linux virtual keyboard.

### Change the app

The Swift source is in `mac/app`. Edit it, raise the version in `mac/app/Info.plist`, and rebuild with `make mac-app` or `make mac-install`. The app is signed ad hoc, without an Apple developer account, so macOS asks for its permissions again after each changed build. [mac/README.md](mac/README.md) covers the source layout, the `--check` and `--snapshot` diagnostics, the Mac settings, and the older Terminal client.

## Development and deployment

The checkout at `~/.local/share/whisper-ptt` is also the running application's source. The development alias points to this same directory. A commit or GitHub push alone does not restart the service. Python changes take effect when the process restarts; GNOME caches extension code until the next login. Private configuration stays outside the repository.

Install GNU Make and Node.js for the local check commands (Arch: `sudo pacman -S --needed make nodejs`). Existing runtime dependencies remain in `venv/`.

```bash
cd ~/.local/share/whisper-ptt
make help
make test         # syntax checks and fast mocked control tests
make test-full    # complete daemon suite; needs runtime dependencies and local sockets
make deploy       # checks, tests, refreshes links, and restarts dictation locally
make status       # systemd status; an inactive service gives a nonzero exit status
make logs         # recent logs; may contain private dictated text
make stop         # stop Whisper and cleanup, and unload cleanup model
make start        # enable both now
make mac-app MAC=<host>      # build the Mac menu bar app over SSH; the .dmg lands in its Downloads
make mac-install MAC=<host>  # build it and install it in the Mac's Applications
```

`make deploy` runs the fast tests, not GPU benchmarks or the full daemon suite. It requires the canonical checkout and an existing environment and local configuration. It starts the service even if it was off, but does not change whether it starts at login. Existing private settings are preserved. The active-process check does not guarantee the microphone or GPU model is ready: inspect `make logs` and try a dictation. When changing the daemon, run `make test-full` before deploying as well.

### Edit, test, deploy, publish

```bash
cd ~/.local/share/whisper-ptt
git switch -c improve-cleanup
# Edit code in your editor.
make test
git diff
git add whisper-ptt.py  # explicitly select the files you changed
git commit -m "Improve cleanup behavior"
make deploy            # run your changes on this computer
# Try Right Ctrl dictation and inspect make logs.
make push              # test and push commits on this branch to GitHub
```

`make push` requires a clean working tree, never creates a commit, and does not deploy. `make publish` runs local deployment and then pushes existing commits; use it after committing and testing the behavior you want to publish. GitHub branch pushes do not merge into `main` automatically. Create a pull request or merge your branch when ready.

To get updates that already exist on your current upstream branch, use `make update`. It requires a clean working tree, pulls with `--ff-only`, and then deploys. It does not discard edits or resolve divergent histories automatically. If checks fail after the pull, the service is not restarted; inspect the failure before proceeding.

### Undo a change

```bash
git log --oneline -10
git revert <commit-to-undo>
make deploy
make push
```

Reverting creates a new commit so shared history stays intact. Save or commit experiments before reverting. For separate experimental worktrees, run tests there, but deploy only from the canonical checkout.

### GNOME UI changes

Run `make test` and `make deploy`, save your work, then log out and back in. The existing extension is linked to this repository; deployment cannot hot-reload its JavaScript reliably in a Wayland session. Never restart or log out of the desktop automatically during deployment.


## Public repository contents

Only source, tests, and example configuration belong here. Runtime configurations, tokens, environments, model downloads, logs, recordings, generated Mac archives, and private before/after dictation collections are excluded. This public repository begins with a curated snapshot; the original local repository retains its earlier history.

## Canonical checkout

For this installation, the maintained checkout is `~/.local/share/whisper-ptt`. Its `.git` directory, service, virtual environment, and source live together. Any development alias must be a symlink to this directory, rather than a second clone. Runtime configuration remains under `~/.config/whisper-ptt` and is never committed.

For experiments, use a branch in the canonical checkout. An experimental worktree can be used for tests, but run `install-links.sh` only from the canonical checkout. Restart the service to load daemon changes.
