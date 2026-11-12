# Settings

The central runtime configuration is `~/.config/whisper-ptt/config.json`. Keep it private: it can contain your network server token. The repository's `config.example.json` documents defaults and is safe to publish; editing the example does not change your running settings.

From the canonical checkout:

```bash
make config   # open private settings with $EDITOR, or nano
make deploy   # check source, test, and restart with the updated settings
make logs     # inspect startup or editing errors; logs can contain dictated text
```

JSON requires double quotes and does not allow comments or trailing commas. Edit individual values rather than replacing your entire file with the following excerpt:

```json
{
  "key": "KEY_RIGHTCTRL",
  "model": "large-v3-turbo",
  "device": "cuda",
  "compute_type": "int8_float16",
  "language": "en",
  "polish": true,
  "polish_model": "qwen3.5:9b",
  "polish_timeout": 120,
  "polish_keep_alive": "10m",
  "polish_min_words": 1,
  "transcribe_while_talking": false,
  "short_entry_min_words": 4,
  "trailing_space": true,
  "type_delay_ms": 2,
  "idle_unload_seconds": 300,
  "idle_park_in_ram": true
}
```

## Form entries

`short_entry_min_words` counts the final output's words across the entire recording, independently of whether cleanup is enabled:

| Value | Behavior |
| --- | --- |
| `4` | One to three words have no terminal period. Four or more keep their punctuation. |
| `3` | Only one or two words lose a terminal period. |
| `0` | Disable this rule. |

`Portland State University.` becomes `Portland State University` at the default value. Question marks, exclamation marks, decimal numbers, and ellipses are preserved. `trailing_space: false` also removes the automatically appended space, which may be useful in forms.

## Transcription and cleanup

- `model`, `device`, `compute_type`, `language`, `initial_prompt`, and `beam_size` configure transcription. `beam_size` defaults to `1`.
- `polish_model` selects an Ollama model already downloaded on this machine. Download a new model with `ollama pull MODEL` before selecting it; changing the setting alone does not download it.
- `polish_prompt` controls the editor's instructions and tone. Preserve the instructions about not answering questions, inventing details, or changing meaning when customizing it.
- `polish_min_words` skips cleanup below this word count, separately from period removal.
- `polish_timeout` is the timeout in seconds for each request. Large rewrites can require a second request to check meaning.
- `polish_min_word_similarity` triggers that check below the configured similarity (current example: `0.25`). `polish_min_length_ratio` rejects output much shorter than the input (current example: `0.2`). These checks are imperfect and are not guarantees of meaning preservation.
- `transcribe_while_talking: false` gives cleanup the complete recording. `true` processes sentence chunks during speech for lower latency.

## Microphone selection and stalled capture

By default, recording follows the system input source. To pin Whisper to one
microphone without changing other applications, list what is connected and pick
one by any part of its name:

```bash
whisper-ptt mic             # list microphones; * marks the one in use
whisper-ptt mic snowball    # record from the first one whose name contains "snowball"
whisper-ptt mic default     # follow the system input again
```

This saves `"microphone"` in `config.json` and restarts the service. The name is
matched, ignoring case, against each PipeWire source's node name and description
every time you press the key, so the choice survives replugging into another port.

When the chosen microphone is not connected, dictation does not record a silent
default source. It shows "Microphone not connected" at startup and on each press,
and works again on the next press after it is plugged in. Set
`"microphone_fallback": true` to record from the system default instead, with a
notification saying so.

An older setup that sets `PIPEWIRE_NODE` in a service drop-in still works and is
used when `"microphone"` is empty.

A source that opens but sends no audio can make PortAudio's graceful `stop()`
wait for a callback indefinitely. Recording now uses `abort()` before closing,
and a two-second no-audio check cancels a stalled capture with a notification.
Captured silence still contains samples and does not trigger this check.

## GPU use and desktop switches

- `idle_unload_seconds` parks Whisper after inactivity; `0` disables idle release.
- `idle_park_in_ram` retains Whisper in system RAM for faster wake-up.
- `polish_keep_alive` is the Ollama retention duration after a cleanup request.
- `ollama_url` defaults to `http://127.0.0.1:11434`. Changing it to a remote server sends text there.

The GNOME switches are live controls. Their saved cleanup preference at `~/.local/state/whisper-ptt/polish` overrides the JSON `polish` default, even after restarting. Use the Cleanup button or `whisper-ptt polish on|off` to change that override. To return to the central JSON default:

```bash
rm -f ~/.local/state/whisper-ptt/polish
```

The UI will create an override again the next time you use its switches. Whisper on enables both features, while off stops dictation and cleanup. Enabling or disabling startup at login remains a systemd setting, controlled by `whisper-ptt enable|disable`.

## Other settings

- `min_duration`: ignore trigger presses shorter than this many seconds.
- `notify`, `notify_timeout_ms`: notification behavior.
- `server`, `server_host`, `server_port`, `server_token`: optional network dictation. Keep the token private; use Tailscale and leave the server disabled if you do not need it. With `server_host` at `"tailscale"`, only peers with a tailnet address of their own are answered; a host set by hand is not filtered.
- `server_control` (default `true`), `control_port` (default: `server_port` + 1): the remote switch, `whisper-ptt-control.service`, which lets the Mac turn Whisper on and off at the desktop. It runs only while `server` is on and uses the same address and token. `make deploy` enables and restarts it; it reads the token on every request, so a changed token needs no restart of this service.
- The Mac client's separate device settings remain in `~/.config/whisper-ptt/mac.json` on the Mac.
- The Mac app's Cleanup switch is sent with each of its requests and applies only to the Mac's dictations. The Terminal client sends none, so the desktop's cleanup setting decides for it.

The Makefile and GNOME extension read the same daemon configuration and saved UI preference rather than maintaining another set of model settings. Most settings take effect on service restart; the cleanup UI preference is read for each dictation.
