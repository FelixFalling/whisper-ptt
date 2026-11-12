# Changelog

## Unreleased

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
