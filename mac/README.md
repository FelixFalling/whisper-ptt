# whisper-ptt on the Mac

Hold **right Option**, speak, let go: the words are pasted where your cursor is. The audio
goes to the desktop over Tailscale and its GPU does the transcribing. If the desktop is off
or asleep, this Mac transcribes it instead, with a slower local model.

There are two ways to run it. **Whisper PTT.app** is a menu bar app with switches for
dictation and cleanup. The older Terminal client (`whisper-ptt-mac.py`) does the same
dictation without the menu. Run one or the other, not both: both would paste every
dictation.

## The menu bar app

### Install

1. Make sure Tailscale is running on this Mac.
2. Once, for the settings file and the fallback that transcribes on this Mac: in Terminal,
   in this folder, run `./install.sh`. It needs `python3`; if that is missing, run
   `xcode-select --install` first. Skip the step if the Terminal client was installed before.
3. Open `Whisper-PTT.dmg` and drag **Whisper PTT** onto **Applications**. To build the .dmg,
   see "Build and change the app" below.
4. Open Whisper PTT. A welcome window asks for three permissions and ticks each one as you
   allow it:
   - **Microphone**, to hear you while you hold the key.
   - **Accessibility**, to paste the text.
   - **Input Monitoring**, to notice right Option in every app. macOS may ask to quit and
     reopen the app after this one.

   If macOS asks whether Whisper PTT may find devices on your local network, allow it: that
   is how it reaches the desktop.

You hear a tick when it starts listening and a pop when the text is pasted. A low thud means
something went wrong; the menu says what.

### The menu

Click the waveform in the menu bar.

| Control | What it does |
| --- | --- |
| **Whisper** | Turns dictation on this Mac on or off. Off, right Option is just a key again. |
| **Cleanup** | On: the desktop fixes grammar and removes filler words. Off: your words as spoken. This switch only affects the Mac's dictations; the desktop's own Cleanup switch stays as it is. |
| Desktop row | Shows whether the desktop answers. Click it to check again. |
| **Last dictation** | Click it to copy the text again, for when it was pasted in the wrong place. |
| **Open at Login** | Starts the app when you log in. |
| **Settings File…** | Opens `~/.config/whisper-ptt/mac.json`. |
| **Show Log** | Opens `~/Library/Logs/Whisper PTT.log`. It records timings, not what you said. |

The menu bar icon changes while it works: a microphone while you talk, a speech bubble while
it transcribes, a slashed waveform when Whisper is off, and a badge when it needs a
permission.

When the desktop is unavailable, the app transcribes on this Mac without cleanup. The Mac
cannot turn the desktop on: if Whisper is off there, switch it on at the desktop (`make
start`, or Whisper in GNOME's system menu).

### Build and change the app

The app's source is in `mac/app` (Swift and SwiftUI). It builds with the Xcode Command Line
Tools; full Xcode is not needed.

From the desktop, over SSH:

```bash
make mac-app MAC=<ssh host of the Mac>       # Whisper-PTT.dmg lands in the Mac's Downloads
make mac-install MAC=<ssh host of the Mac>   # also replaces /Applications/Whisper PTT.app and opens it
```

On the Mac itself: `mac/app/build.sh` (or `build.sh --install`).

| File | What is in it |
| --- | --- |
| `Dictation.swift` | Hold, record, send, paste; the switches and the status the menu shows |
| `Panel.swift`, `Setup.swift` | The menu and the welcome window |
| `KeyWatcher.swift` | Hears right Option in every app |
| `Audio.swift` | Recording and the 16 kHz WAV the desktop wants |
| `Desktop.swift` | Requests to the desktop's server |
| `LocalTranscriber.swift`, `Resources/fallback.py` | Transcription on this Mac with mlx-whisper |
| `System.swift` | Pasting, permissions, the log, Open at Login |
| `Check.swift` | `--check` and `--snapshot`, below |

Two tools help without clicking through the app:

```bash
APP="/Applications/Whisper PTT.app/Contents/MacOS/WhisperPTT"
"$APP" --check                 # settings, desktop and fallback; exit status 0 when all answer
"$APP" --check speech.wav      # also transcribes a 16 kHz mono WAV with cleanup off and on
open -n -W "/Applications/Whisper PTT.app" --args --snapshot /tmp/shots   # menu and welcome window as PNGs
```

Make a test WAV with `say -o s.aiff "some words"` and
`afconvert -f WAVE -d LEI16@16000 -c 1 s.aiff s.wav`.

The app is signed ad hoc, which needs no Apple developer account. macOS ties the
permissions it grants to that exact build, so after installing a changed app, the welcome
window asks again. If System Settings already shows Whisper PTT switched on, remove it from
the list with the minus button and allow it again. Raise `CFBundleShortVersionString` and
`CFBundleVersion` in `mac/app/Info.plist` when you change the app.

Do not use `@State` in the views: in the macOS 27 SDK it is a macro whose plugin only comes
with full Xcode, so the build fails with the Command Line Tools. Keep view state in an
`ObservableObject`, as `Hover` and `Dictation.copied` do.

## The Terminal client

1. Make sure Tailscale is running on this Mac.
2. In Terminal, in this folder: `./install.sh`
3. Start it: `~/.local/share/whisper-ptt-mac/run`
4. macOS asks for permissions. Allow them for **Terminal**, then quit and start it again:
   - Microphone: macOS asks the first time you hold right Option.
   - System Settings, Privacy & Security, **Accessibility**: turn on Terminal (it pastes
     the text).
   - System Settings, Privacy & Security, **Input Monitoring**: turn on Terminal (it hears
     the right Option key).

The desktop's own Cleanup switch decides for the Terminal client (`whisper-ptt polish off`
on the desktop turns it off). Leave the Terminal window open (minimised is fine); it runs
as long as that window does.

`./install.sh --autostart` runs it in the background at login instead of in Terminal.
macOS then asks for the permissions again, this time for the venv's `python3`; add it under
Accessibility and Input Monitoring. If it starts but never hears you, macOS has blocked the
background microphone: stay with the Terminal way, or use the app.

## How dictation behaves (both)

- Holding right Option and pressing another key (as for accents) cancels the dictation,
  and the tick only sounds once a press has lasted a third of a second, so accents stay
  silent. It never pastes while you are still holding Option.
- After five idle minutes the desktop parks its model in RAM to free the graphics card;
  waking it adds about a tenth of a second, and it starts the moment you press the key.
- The first time the desktop is away, the fallback downloads its model (about 1.6 GB).
- The text is pasted through the clipboard, and what was on the clipboard is put back.

## Settings

`~/.config/whisper-ptt/mac.json`, shared by the app and the Terminal client. Restart either
after changing it.

- `key`: right Option is `alt_r`; right Command is `cmd_r`. Also `ctrl_r`, `shift_r`, and
  the left keys (`alt_l`, `cmd_l`, ...).
- `initial_prompt`: names and jargon Whisper keeps getting wrong.
- `fallback`: `false` to never transcribe on this Mac.
- `server` and `token` connect it to the desktop. Keep the token private: it is the only
  thing that lets a device on your tailnet use the desktop's transcriber.
- App only: `transcribe_timeout` (seconds to wait for the desktop, default 120),
  `restore_clipboard`, `sounds`, `fallback_python` (the venv with mlx-whisper).
