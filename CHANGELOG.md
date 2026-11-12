# Changelog

## Unreleased

- Mac app 1.2: signed with a certificate made on the Mac (`mac/app/signing.sh`) instead of
  ad hoc, so the permissions macOS grants survive rebuilds. Ad hoc builds showed
  "Allow Accessibility" while System Settings had Whisper PTT switched on, because that
  switch belonged to an earlier build. The welcome window has a Reset for such entries.
- GNOME: the Whisper button has a menu (microphone, copy the last dictation, log,
  settings file) and says what dictation is doing; the top-bar microphone turns into a
  red dot while recording, three dots while transcribing and a warning when something
  needs attention. The extension no longer polls: it ran a Python process every three
  seconds, and now follows systemd and two small files as they change.
- Cleanup: hand the dictation to the model as text to edit, and check a wordier edit for
  meaning instead of discarding it. On three weeks of real dictations, 27 of the 28
  rejected cleanups now go through; the other is rightly refused. A cleanup that is not
  used is a quiet banner, no longer a critical one that stays on screen.
- A Right Ctrl shortcut no longer wakes the models: Whisper and the polish model are
  loaded once a press has lasted a quarter of a second.
- The trigger key is ignored while your desktop session is not on screen (the login
  screen, another user), so a service the Mac switched on cannot record there.
- Settings of the wrong kind or with unknown names are reported and replaced by the
  default instead of failing later; `notify_progress`, `require_desktop_session` and
  `polish_max_length_ratio` are new.
- The idle service no longer wakes ten times a second, the two servers sleep until a
  request comes, switching Cleanup on no longer keeps the button busy while the model
  loads, and stopping the service is given 15 seconds at most.
- Switch Whisper on and off at the desktop from the Mac's menu. A new always-on service,
  `whisper-ptt-control.service`, answers the Mac when the dictation service is stopped.
  Mac app 1.1 shows the desktop's switch, tells "Whisper is off there" from "desktop not
  reachable", and has `--desktop on|off|status` for the command line.
- Server hardening: answer only peers with a tailnet address (binding to the Tailscale
  address did not keep a LAN machine out), drop connections that go quiet, never follow a
  redirect from the Mac, warn about a short token, keep the token zip private.
- Mac fallback: load the model while the key is held, decode and punctuate like the
  desktop, return nothing for a silent recording, and stop the helper after ten idle
  minutes so its memory is free again.
- Mac app: check on the desktop and its permissions once a minute instead of every two
  seconds, and again after waking from sleep.
- A failed cleanup of the Mac's dictation no longer raises a banner on the desktop;
  `whisper-ptt polish on` warms the model at the configured `ollama_url`.
- Add Whisper PTT.app, a menu bar app for the Mac with Whisper and Cleanup switches,
  a welcome window for its permissions, and `make mac-app` / `make mac-install` to build
  it on the Mac over SSH.
- Let the Mac choose cleanup for its own dictations (`X-Whisper-Cleanup` header) and
  report the desktop's name from `/health`.
- Release the microphone promptly even when its source stalls; cancel captures
  that receive no audio and report the selected source at startup.
- Show raw transcription and cleaned-up output in separate fenced log blocks,
  including cleanup fallback status, paragraphs, and timing.
- Add `whisper-ptt logs --follow` for readable live logs.
- Stop showing a "Polishing…" notification before every cleanup.
- Support GNOME Shell 51 in the Whisper Controls extension, and warn from `make deploy`
  when the running GNOME version is missing from its metadata.
- Choose the microphone with `whisper-ptt mic NAME` (any part of its name) or the
  `microphone` setting; `whisper-ptt mic` lists what is connected.
- Say "Microphone not connected" (at startup and on each press) when the chosen
  microphone is unplugged, instead of recording a silent default source;
  `microphone_fallback: true` uses the system default instead.

- Publish the Linux push-to-talk daemon, Mac client, systemd integration, and tests.
- Add Whisper and Cleanup controls to GNOME Quick Settings.
- Add combined start/stop and explicit cleanup-model unloading through desktop controls.
- Support configurable rewrite prompts and a local meaning check for large edits.
- Provide an example configuration for whole-recording cleanup with Qwen3.5 9B.
