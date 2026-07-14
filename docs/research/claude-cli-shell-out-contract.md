# The `claude` CLI shell-out contract

Verified on this machine (2026-07-13) by running it, not by reading docs. Inputs were the real
prompts (`pass1.txt`, `pass2.txt`) and the real samples (`caso-02/03/04`) in
`.scratch/dictation-tool/`. CLI version **2.1.208**, a Mach-O arm64 binary at
`/Users/gbtagliari/.local/bin/claude`.

## The command

Both passes are the same invocation; only `--system-prompt` and the input differ.

```
/Users/gbtagliari/.local/bin/claude \
  --print \
  --model claude-sonnet-5 \
  --effort low \
  --system-prompt "<contents of pass1.txt | pass2.txt>" \
  --tools "" \
  --safe-mode \
  --no-session-persistence \
  --output-format json
```

The transcript goes in on **stdin**. Pass 1 takes the raw Whisper transcript; pass 2 takes pass 1's
output. Read the rewritten text from the JSON field `result` — **but only after checking `is_error`**
(see [Failure](#failure-exit-code-tells-the-truth-subtype-does-not)).

Every flag is load-bearing:

| Flag | Why it cannot be dropped |
|---|---|
| `--effort low` | **The big one.** Left unset, the CLI defaults to a high-effort/thinking mode that is catastrophic here: pass 1 on `caso-04` emitted **5986 output tokens** for a task whose correct output is ~450, taking **54 s** and costing **$0.091**. With `--effort low`: 441 tokens, 5.3 s, $0.008. It also removes wild run-to-run nondeterminism. See [Effort](#effort-the-single-most-important-flag). |
| `--safe-mode` | Disables `CLAUDE.md` discovery, skills, plugins, hooks, MCP. Without it, a run whose cwd is this repo pulled in **7678 input tokens** of context vs **516** with it — the repo's `CLAUDE.md` and the user's global `MEMORY.md` get injected into every dictation. That is both a fidelity leak and a privacy leak. Auth still works normally under `--safe-mode`. |
| `--tools ""` | The passes are pure text transforms. Nothing should be able to read or write a file. |
| `--system-prompt` | Puts the prompt in the system slot, where it is **prompt-cached** (`cache_read_input_tokens: 1392` on repeat runs). Concatenating prompt+transcript into one user argument works too, but forfeits the cache and puts private dictation in `argv`, visible to `ps`. Prefer system prompt + stdin. |
| `--no-session-persistence` | Otherwise every utterance writes a session transcript to `~/.claude/projects/`. |
| `--output-format json` | The only way to detect failure safely. With `text`, an error message is printed **to stdout** where the rewritten text belongs. |

Pin the **full model id** (`claude-sonnet-5`), not the `sonnet` alias: the alias will silently
re-point when a new Sonnet ships, changing the behaviour the prompts were calibrated against.

## Effort: the single most important flag

Pass 1 is mechanical — it re-emits the transcript verbatim with markers, so correct output length
≈ input length. Unset effort makes the model *deliberate* about that, at enormous cost.

`caso-04` (1079 B in), pass 1, Sonnet:

| effort | wall | output tokens | cost |
|---|---|---|---|
| _(unset)_ | 54.4 s | 5986 | $0.091 |
| _(unset)_, repeat | 5.2 s | 449 | $0.008 |
| `low` | 5.2 s | 441 | $0.008 |
| `low`, repeat | 5.4 s | 441 | $0.008 |

Unset effort is not merely slow, it is **unstable** — the same input swung between 449 and 5986
output tokens across runs. `--effort low` collapses the spread. Output fidelity is unaffected: at
`low` the pass-1 output is 1093 B against 1079 B in, i.e. the text is still echoed whole.

## Haiku is not a viable fallback

The premise going in (from the bake-off) was that Sonnet does the best work and **Haiku is the
pass-1 fallback**. Measured, that is backwards. `caso-04`, pass 1, both at `--effort low`:

| model | wall | output tokens | cost |
|---|---|---|---|
| `claude-sonnet-5` | 5.6 s / 5.0 s | 463 / 468 | $0.008 |
| `claude-haiku-4-5` | 61.5 s / 50.1 s | 7974 / 5257 | $0.042 / $0.028 |

**Haiku ignores `--effort low`** and thinks its way through a task that needs no thinking. It is
~10× slower and ~4× *more expensive* than Sonnet here. Quality is comparable (1093 B out, markers
present), but there is no reason to reach for it.

Consequence: **do not set `--fallback-model haiku`.** It is a downgrade trap — if Sonnet is
overloaded, the fallback costs more and takes ten times longer. Sonnet at `--effort low` is
simultaneously the best, the fastest, and the cheapest option. There is no fallback model; there is
only retry.

## Failure: exit code tells the truth, `subtype` does not

Unlike `mlx_whisper` (which exits 0 on every failure), **`claude` exits 1 on failure.** The exit
code is trustworthy. Measured:

| Case | `rc` | `is_error` | `api_error_status` | stdout | Time to fail |
|---|---|---|---|---|---|
| Success | 0 | `false` | `null` | the JSON envelope | — |
| Bad model name | 1 | `true` | `404` | JSON, `result` = English error prose | fast |
| Bad/expired credentials | 1 | `true` | `401` | JSON, `result` = `Invalid API key · Fix external API key` | 3 s |
| Not logged in | 1 | `true` | **`null`** | JSON, `result` = `Not logged in · Please run /login` | fast |
| API unreachable | 1 | `true` | **`null`** | JSON, `result` = `API Error: Unable to connect to API (ConnectionRefused)` | **179 s** |
| Empty stdin | 1 | — | — | **empty; not JSON.** Plain text on stderr | 2 s |
| Binary missing | 127 (shell) | — | — | — | — |

Three traps in that table:

1. **`subtype` is a liar.** It reads `"success"` in *every* error case above. Never branch on it.
   The truthful fields are **`is_error`** (universal) and `api_error_status` (HTTP status, but
   `null` for network and auth-state errors). **Check `is_error` first, and `rc != 0`.**

2. **`--output-format text` puts the error message on stdout.** A failing run with `text` prints
   `There's an issue with the selected model (...)` to **stdout**, with **stderr empty (0 bytes)**,
   and exits 1. A caller that reads stdout and ignores the exit code will file that English prose in
   the log as the user's dictated text. This is the `mlx_whisper` silent-failure trap wearing a new
   costume. Use `json`, and gate on `is_error`.

3. **Empty stdin produces no JSON at all** (`Error: Input must be provided...` on stderr, rc=1). A
   JSON parser pointed at stdout will throw. Handle "stdout is not JSON" as its own case — or, better,
   never invoke the CLI on an empty transcript (see the silence guard in
   [`mlx-whisper-shell-out-contract.md`](./mlx-whisper-shell-out-contract.md)).

### No timeout of its own

An unreachable API retried for **179 seconds** before giving up. There is no built-in deadline. The
app **must impose its own timeout** on the subprocess and kill it. Feeds #8 (failure states) and #9
(concurrency).

### Rate limiting: untested

I could not force a 429 without actually exhausting the subscription. The detection recipe is
known — `is_error: true` with `api_error_status: 429` — but the *retry behaviour* is not measured.
Given the 179 s connection-refused storm, assume the CLI may also retry a 429 for a long time, and
let the app's own timeout be the backstop. Do not treat this row as verified.

## The app cannot be sandboxed

This is the question that could have killed the approach. It does not, but it constrains the build.

**Credentials live under `$HOME`.** `~/.claude/.credentials.json` (968 B, mode `0600`) — a keychain
item `Claude Code-credentials` also exists, but the file is what is actually required. Auth is
**OAuth against the subscription**, not an API key (`ANTHROPIC_API_KEY` is unset on this machine).

Run with `HOME` pointed at an empty directory, the CLI fails with **`Not logged in · Please run
/login`** (rc=1, `is_error: true`).

That experiment *is* the sandbox test. **Under macOS App Sandbox, `HOME` is rewritten to the app's
container** (`~/Library/Containers/<bundle-id>/Data`). A sandboxed app's subprocess would therefore
look for `<container>/.claude/.credentials.json`, not find it, and fail to authenticate — exactly
the failure I reproduced. On top of that, a sandboxed app may not exec binaries outside its bundle.

**Conclusion: do not enable App Sandbox.** For a locally-built personal menubar app this costs
nothing — App Sandbox is only mandatory for Mac App Store distribution, and distribution is already
out of scope on the map. Worth recording as a deliberate constraint rather than an accident: **if the
app is ever sandboxed, transcription and organization both break at the auth layer.**

## The environment the subprocess needs

**None of the three binaries are on a GUI app's PATH.** An app launched from Finder/Dock inherits
`/usr/bin:/bin:/usr/sbin:/sbin`. Measured against that PATH:

| binary | actual location | on GUI PATH? |
|---|---|---|
| `claude` | `~/.local/bin/claude` | **no** |
| `mlx_whisper` | `/opt/homebrew/bin/mlx_whisper` | **no** |
| `ffmpeg` | `/opt/homebrew/bin/ffmpeg` | **no** |

**Invoke all three by absolute path.** Do not rely on `PATH` lookup, and do not assume a shell will
resolve them — there is no shell (build `Process.arguments` as an array, never a shell string).

The subprocess **must inherit `HOME`** (else: not logged in). A scrubbed environment of
`HOME`, `USER`, `PATH`, `TMPDIR` is sufficient — every measurement in this document was taken under
exactly that env.

One caveat worth knowing: running `claude` *from inside another Claude Code session* inherits
`CLAUDECODE=1` and friends, which inflated wall time from ~3 s to ~11.7 s. Irrelevant to the shipped
app, but it will confuse anyone benchmarking from an agent session.

## Output is clean

Under `--print`, stdout carries only the JSON envelope (or, with `text`, only the rewritten text).
No banner, no chrome. Even `--debug` writes nothing to stdout in print mode (use `--debug-file`).

Verified end-to-end: pass 1 → pass 2 chained on `caso-04` reproduces the bake-off's
`final-04.txt` — `[? se profissional ?]` preserved, `barra sync` → `` `/sync` ``, `barra home` →
`` `/home` ``, paragraphs broken. The prompts work as-is through this invocation.

Note pass 1 is **not deterministic**: two identical invocations of `caso-02` differed in whether they
marked `<dup>o time</dup>`. There is no temperature flag. Do not build anything that assumes a stable
pass-1 output for a given input (no output-hash caching, no "reprocess must match").

## Timing and cost

Sonnet, `--effort low`, warm, sequential. Per utterance, both passes:

| sample | transcript | pass 1 | pass 2 | total LLM | cost |
|---|---|---|---|---|---|
| `caso-02` | 214 B | 3.4 s | 3.2 s | **6.6 s** | $0.014 |
| `caso-03` | 521 B | 3.7 s | 4.0 s | **7.8 s** | $0.019 |
| `caso-04` | 1079 B | 5.5 s | 6.3 s | **11.8 s** | $0.027 |

**Per pass: wall ≈ 2.7 s + 0.0026 × transcript_bytes.** Both passes together ≈ **5.4 s + 0.006 ×
bytes**. Fixed CLI startup is ~1.2 s of that per invocation.

Stacked on `mlx_whisper` (3.3 s + 0.024 × audio_seconds, from #2), a **100 s dictation costs ~5.7 s
transcribing + ~11.8 s organizing ≈ 17.5 s end-to-end.** This is why the product is asynchronous.

### Cost is not zero — it is quota

The map's premise is "marginal cost per utterance stays zero". Precisely: **no dollars are billed**
(it is subscription OAuth, not an API key), but each utterance consumes **$0.014–$0.027 of
subscription quota**, and quota is finite. Heavy dictation days can plausibly hit a rate limit. That
is a real failure state, not a hypothetical — it belongs in #8.

`--max-budget-usd` exists (print mode only) if a hard per-invocation cap is ever wanted.

### The session-title tax

Every invocation fires a **second, unrequested API call** — `source=generate_session_title`, on
Haiku, ~581 in / 23 out, ~$0.0007. It survives `--safe-mode`, `--no-session-persistence` and
`--tools ""`. It runs **in parallel** with the real request, so it costs no latency, only ~5–25% of
the per-call cost. `--bare` would remove it, but `--bare` forces API-key auth (OAuth and keychain are
never read), which would convert the app from "free on subscription" to metered billing. **Not worth
it. Pay the tax.**

## Concurrency

Two pass-1 invocations at once both succeed and both return correct output: `caso-03` + `caso-04`
took **5.4 s concurrently vs ~9.2 s sequentially**. Unlike `mlx_whisper` (GPU-bound, ~1.9 GB each),
this stage is network-bound and parallelises cleanly.

So the pipeline has an asymmetry worth knowing when #9 is decided: **transcription wants to be
serialized; organization does not have to be.**

## Consequences for the app

1. Absolute paths for all three binaries. `Process.arguments` as an array, never a shell string.
2. Pass `HOME` through to the subprocess, or auth fails.
3. **Do not enable App Sandbox.** It breaks auth irrecoverably.
4. `--effort low` on every call. Unset costs 10× the latency and 11× the quota.
5. Pin `claude-sonnet-5` by full id. No Haiku fallback — it is slower and pricier.
6. `--safe-mode` on every call, or `CLAUDE.md` and `MEMORY.md` leak into the dictation.
7. `--output-format json`; treat `rc != 0` **or** `is_error == true` as failure. Never trust
   `subtype`. Never use `--output-format text` — errors land on stdout as if they were content.
8. Impose an app-side timeout. The CLI will retry a dead network for ~3 minutes.
9. Never invoke on an empty transcript — it returns non-JSON.
10. Budget ~5.4 s + 0.006 × bytes for the LLM stage; ~$0.02 of subscription quota per utterance.
