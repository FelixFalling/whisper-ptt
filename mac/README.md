# whisper-ptt on the Mac

Hold **right Option**, speak, let go: the words are pasted where your cursor is. The audio
goes to the desktop  over Tailscale and its GPU does the transcribing. If
the desktop is off or asleep, this Mac transcribes it instead, with a slower local model.

## Install (once)

1. Make sure Tailscale is running on this Mac (it already is on your tailnet).
2. In Terminal, in this folder: `./install.sh`
   It needs `python3`; if it says it is missing, run `xcode-select --install` first.
3. Start it: `~/.local/share/whisper-ptt-mac/run`
4. macOS asks for permissions. Allow them for **Terminal**, then quit and start it again:
   - Microphone: macOS asks the first time you hold right Option.
   - System Settings, Privacy & Security, **Accessibility**: turn on Terminal (it pastes
     the text).
   - System Settings, Privacy & Security, **Input Monitoring**: turn on Terminal (it hears
     the right Option key).

You hear a tick when it starts listening and a pop when the text is pasted. A low thud
means neither the desktop nor this Mac could transcribe it; the Terminal window says why.

## Day to day

- The desktop cleans up grammar and filler words before sending the text back (its polish
  mode, on by default; `whisper-ptt polish off` on the desktop turns it off). The fallback
  on this Mac types the words as spoken.

- Leave the Terminal window open (minimised is fine). It runs as long as that window does.
- Holding right Option and pressing another key (as for accents) cancels the dictation,
  and the tick only sounds once a press has lasted a third of a second, so accents stay
  silent. It never pastes while you are still holding Option.
- After five idle minutes the desktop parks its model in RAM to free the graphics card;
  waking it adds about a tenth of a second, and it starts the moment you press the key.
- The first time the desktop is away, the fallback downloads its model (about 1.6 GB).

## Start at login (optional)

`./install.sh --autostart` runs it in the background at login instead of in Terminal.
macOS then asks for the permissions again, this time for the venv's `python3`; add it under
Accessibility and Input Monitoring. If it starts but never hears you, macOS has blocked the
background microphone: stay with the Terminal way.

## Settings

`~/.config/whisper-ptt/mac.json`, then restart it:

- `key`: right Option is `alt_r`; right Command is `cmd_r`.
- `initial_prompt`: names and jargon Whisper keeps getting wrong.
- `fallback`: `false` to never transcribe on this Mac.
- `server` and `token` connect it to the desktop. Keep the token private: it is the only
  thing that lets a device on your tailnet use the desktop's transcriber.
