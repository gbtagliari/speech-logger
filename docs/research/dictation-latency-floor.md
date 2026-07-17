# Dictation latency: where the seconds actually are

Verified on this machine (2026-07-16) by measuring, not by reading docs. `mlx-whisper` 0.4.3,
`whisper-large-v3-turbo`, `HF_HUB_OFFLINE=1`, model already cached. Clips cut from the real pt-BR
samples in `.scratch/dictation-tool/samples/`. Extends
`docs/research/mlx-whisper-shell-out-contract.md`, which measured the CLI only.

## The short version

The ticket asked buffer vs temp file. **Buffer is worth ~0.1 s. Killing the per-utterance process is
worth ~2.9 s.** The file was never the cost; the process was. Everything below is that one sentence
with numbers behind it.

## What was asked

**Does the CLI take anything but a path?** Yes — `-` reads stdin (`cli.py:236-240`), which calls
`load_audio(from_stdin=True)` and still shells out to `ffmpeg` with `pipe:0` (`audio.py:43-46`). The
output name defaults to `content`. Measured: **3.01 s** for a 5 s clip, indistinguishable from passing
a path. Stdin removes the temp file, not the latency.

**Does the Python API take a buffer?** Yes: `transcribe(audio: Union[str, np.ndarray, mx.array], ...)`
(`transcribe.py:62-63`). A float32 16 kHz mono waveform goes straight in — no `ffmpeg`, no file.

**Can it transcribe incrementally during the hold?** Pointless under 30 s. Whisper pads the mel to a
30 s window (`transcribe.py:150`), so a 1 s clip and a 25 s clip cost nearly the same. Chunking a
dictation splits one window into several and makes it slower, not faster.

## The numbers

**CLI, one process per utterance, 5 s clip** (3 runs each):

| Input | Wall |
|---|---|
| wav 48 kHz stereo (what `AVAudioEngine` records) | 3.03 – 4.16 s |
| wav 16 kHz mono | 2.50 – 2.75 s |
| mp3 | 2.36 – 2.54 s |
| wav 16 kHz mono via stdin (`-`) | 3.01 s |

Input shape is close to noise. The mp3 **encode** step costs **0.14 s** for a 5 s clip, so dropping it
for dictation saves 0.14 s — real, and irrelevant at this scale.

**Resident process, warm:**

| Cost | Time | Paid |
|---|---|---|
| `import mlx_whisper` | 1.00 s | once |
| model load (first call) | ~1.9 s | once — `ModelHolder` caches on a class var (`transcribe.py:50-59`) |
| transcribe 5 s **from buffer** | **0.77 s** | per utterance |
| transcribe 5 s **from path** | 0.87 s | per utterance (`ffmpeg` decode of a 5 s wav = 0.199 s) |

**Duration scaling, warm, from buffer:** 1 s → 0.70 s · 3 s → 0.71 s · 10 s → 0.74 s · 25 s → 0.87 s ·
35 s → 1.69 s. Flat until the 30 s window closes, then it steps.

**Peak RSS 1.86 GB**, held for the life of the process.

## The budget

- **CLI, as today:** ~2.4 – 4 s for a 5 s dictation. **The ~1-2 s target is unreachable**, by any
  arrangement of files, stdin, formats, or chunking.
- **Resident process:** ~0.8 s, target met with room to spare.

The ~3 s the CLI pays is ~1.0 s of interpreter + import and ~1.9 s of model load — built per
utterance, thrown away per utterance. There is no third option: `mlx_whisper` ships no daemon mode.

## Consequences

1. **Temp file is fine.** The owner's registered position holds, and it is cheap: path vs buffer is
   ~0.1 s, and a wav needs no mp3 pass (another 0.14 s).
2. **~1-2 s buys a resident Python process holding 1.86 GB idle.** That is ADR-0002 territory — "shell
   out to three binaries" assumes a process per invocation — not an implementation detail. It is a
   decision, and it is the only lever that moves this number.
3. **A premise needs settling first.** The map's Notes say latency is *not* the pain; this ticket's
   body assumes ~1-2 s. If latency really is not the pain, the CLI stands at ~3 s and nothing here
   needs to change. The measurement does not decide that — it only prices it.
4. **Chunking during the hold is dead** as an idea, for any dictation under 30 s.
5. **The hope in #29 does not land for free.** Buffer/stream exists *only* inside a resident process,
   so dictation cannot quietly sidestep the lane and the file-based `mlx_whisper` — it sidesteps them
   by becoming a different process model, which is a bigger decision, not a smaller one.
6. Braindump gains nothing from any of this: it is asynchronous, and ~3 s of startup on a 3-minute
   recording is invisible.
