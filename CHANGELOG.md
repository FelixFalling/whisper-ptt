# Changelog

## Unreleased

- Release the microphone promptly even when its source stalls; cancel captures
  that receive no audio and report the selected source at startup.
- Show raw transcription and cleaned-up output in separate fenced log blocks,
  including cleanup fallback status, paragraphs, and timing.
- Add `whisper-ptt logs --follow` for readable live logs.

- Publish the Linux push-to-talk daemon, Mac client, systemd integration, and tests.
- Add Whisper and Cleanup controls to GNOME Quick Settings.
- Add combined start/stop and explicit cleanup-model unloading through desktop controls.
- Support configurable rewrite prompts and a local meaning check for large edits.
- Provide an example configuration for whole-recording cleanup with Qwen3.5 9B.
