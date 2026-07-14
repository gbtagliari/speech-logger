# The `mlx_whisper` shell-out contract

Verified on this machine (2026-07-13) by running it, not by reading docs. Inputs were the real
samples in `.scratch/dictation-tool/samples/` (17 s, 55 s, 102 s of pt-BR dictation).

## The command

```
/opt/homebrew/bin/mlx_whisper <audio> \
  --model mlx-community/whisper-large-v3-turbo \
  --language pt \
  --condition-on-previous-text False \
  --temperature 0 \
  --verbose False \
  --output-format txt \
  --output-name <dot-free-slug> \
  --output-dir <dir>
```

Every flag is load-bearing:

| Flag | Why it cannot be dropped |
|---|---|
| `--model` | Default is `whisper-tiny`, silently. Tiny mis-hears "Packers" as "vali" and "daily" as "dele" on our own samples. |
| `--language pt` | Auto-detect drifts on short clips. |
| `--condition-on-previous-text False` | Guards the **repetition loop**: conditioned on its own output the decoder can emit one token for minutes and swallow that stretch of audio. No error, no truncation. |
| `--output-name` | Without it the name is derived from the input stem and **truncated at the first dot**. Pass a slug we chose, so the path we predict is the path that exists. |
| `--verbose False` | Otherwise stdout carries an `Args: {...}` dump plus timestamped segments. |

Version: `mlx-whisper` 0.4.3, Homebrew, shebang `#!/opt/homebrew/opt/python@3.14/bin/python3.14`.
No venv is involved. **Risk:** that shebang pins a Homebrew Python minor version; the Homebrew
`whisper` binary on this machine is already dead this exact way (its shebang points at a removed
`python@3.8`). A `brew upgrade python` can break the app's transcription without touching the app.

## Three binaries, not two

`mlx_whisper` decodes audio by shelling out to **`ffmpeg`** — always, for every format including
wav (`mlx_whisper/audio.py:load_audio`, "Requires the ffmpeg CLI in PATH"). With `ffmpeg` off the
PATH it dies with `FileNotFoundError: 'ffmpeg'` and writes nothing.

So the app depends on **`mlx_whisper` + `ffmpeg` + `claude`**. Preflight must check all three.

## Input

Anything ffmpeg can decode; it downmixes and resamples to 16 kHz mono internally.

A wav straight from `AVAudioEngine` (**48 kHz, 16-bit, stereo**) transcribes byte-identically to a
hand-prepared 16 kHz mono wav. **The app does not need to resample, convert, or touch ffmpeg
itself.** Hand the recorded file over as-is.

## Output

- Writes `<output-dir>/<output-name>.txt`. It does **not** write the transcript to stdout under
  `--verbose False`.
- On success stdout is **empty** and stderr still holds a HuggingFace `Fetching 4 files:` progress
  bar. **Non-empty stderr is not a failure signal.**
- `--output-format json` is available if segments/timestamps are ever wanted; `txt` is enough for us.

## Exit codes: unusable

**`mlx_whisper` exits 0 on every failure tested.** `cli.py` wraps the transcribe call in
`try/except Exception`, prints a traceback, prints `Skipping <file> due to ...`, and falls out of
the loop normally.

Measured, every one of them `rc=0`:

| Case | `rc` | Output file | stderr |
|---|---|---|---|
| Success | 0 | written | HF progress bar |
| Missing file | 0 | **none** | `CalledProcessError` from ffmpeg |
| Corrupt / empty file | 0 | **none** | `CalledProcessError` from ffmpeg |
| Nonexistent model repo | 0 | **none** | `HTTPStatusError` (404 from HF) |
| `ffmpeg` not on PATH | 0 | **none** | `FileNotFoundError: 'ffmpeg'` |
| **Silence** | 0 | **written, `"E aí\n"`** | HF progress bar |

**The success signal is the output file: it exists and is non-empty.** `Process.terminationStatus`
tells us nothing. Anything that reads the exit code will report a dead transcription as a success.

### Silence hallucinates

One second of digital silence produced `E aí` — not an empty file, not an error. A hotkey brushed
by accident yields a plausible-looking transcript that would sail into the LLM pass and land in the
log. A guard belongs upstream of transcription (minimum duration and/or audio energy), not here.
Feeds #6 (audio capture) and #8 (failure states).

## Timing (warm, model already cached)

| Audio | Wall |
|---|---|
| 17.3 s | 3.7 s |
| 54.8 s | 4.8 s |
| 102.1 s | 5.7 s |

**wall ≈ 3.3 s + 0.024 × audio_seconds.** Fixed process + model-load cost dominates: a 30 s
dictation costs ~4 s, and 90% of that is startup, not decoding. Peak RSS ~1.86 GB per process.

There is no warm daemon — every invocation pays the ~3.3 s load. If per-utterance latency ever
matters, the lever is a resident process, not a faster model.

## Cold start

First run downloads `mlx-community/whisper-large-v3-turbo` (**~1.5 GB**) to
`~/.cache/huggingface/hub/models--mlx-community--whisper-large-v3-turbo/` (a `config.json` and a
`weights.safetensors`). It is already cached on this machine.

**Once cached, no network is needed:** a run with `HF_HUB_OFFLINE=1` succeeds and produces identical
output. Left unset, every run consults HuggingFace (that `Fetching 4 files` bar; a bad model name
returns a live 404). Recommend the app set **`HF_HUB_OFFLINE=1`** in the subprocess environment once
the model is known-cached, so a dictation never stalls on the network. The tradeoff: with
`HF_HUB_OFFLINE=1` and no cached model, it fails outright, so first-run download must be a deliberate
preflight step rather than a side effect of the first dictation. Feeds the preflight fog.

## Concurrency

Two invocations at once **work** — both exit 0, both write correct transcripts. They contend for the
GPU rather than crash: the 55 s + 102 s pair took **8.8 s concurrently vs 11.1 s sequentially**, and
each process holds its own ~1.9 GB.

Parallelism buys ~20% and costs double the memory. **Serialize transcription in a queue**; the
concurrency decision (#9) is free to do so without a performance argument against it.

## Consequences for the app

1. Build the argv as an array (Swift `Process.arguments`) — never a shell string.
2. Ignore `terminationStatus`. Success = output file exists, non-empty.
3. Preflight three binaries: `mlx_whisper`, `ffmpeg`, `claude`.
4. Feed the recorded wav straight through, no conversion.
5. Guard silence/too-short recordings before transcription.
6. Serialize transcriptions; budget ~3.3 s fixed + 0.024×duration.
7. Pin the model download to an explicit preflight step; run transcription with `HF_HUB_OFFLINE=1`.
