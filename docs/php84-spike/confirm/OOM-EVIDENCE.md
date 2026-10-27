# Directly capturing the PHP2Shell OOM event (CVE-2026-109618 / -109619)

The version policy (`confirm-php2shell.sh` Layer 1) is the authoritative verdict. This document
describes how `--active` goes one step further and **captures the out-of-memory event itself** as
evidence, rather than inferring a crash from differential HTTP behaviour the way the vendored
scanner does on its own.

## What we capture and why

PHP2Shell is a bug in PHP's **request-startup multipart parser**: a multipart body whose field
name is a deeply nested array key drives an unbounded allocation. On a vulnerable PHP that
exhausts memory; the CVE's severity comes from the uninitialised memory left after the OOM
`longjmp`, but the **observable, capturable precondition is the OOM**. The signature is PHP's own
fatal:

```
PHP Fatal error:  Allowed memory size of 536870912 bytes exhausted (tried to allocate 4096 bytes) in Unknown on line 0
```

`in Unknown on line 0` is the tell: the exhaustion happens in the parser during request startup,
with no userland file/line. That is the runtime bug, not anything in morgue.

Under `php -S` the worker returns an empty/garbled response on the crash, so the fatal text is
**not in the HTTP body** (Session 4 saw exactly this — the scanner's "HTTP 500 with an empty body"
tier). The fatal only exists in PHP's **own error channel**, so we capture it server-side, together
with the memory high-water mark and the container's state, for a holistic picture of the event.

The four channels `--active` records into `out/evidence/` (gitignored) and the result JSON's
`oom_evidence` block:

1. **PHP fatal** — the probe container runs with `-d log_errors=On -d display_errors=On
   -d error_log=/evidence/php-error.log`; PHP writes the fatal there synchronously as it is raised
   (so it survives a worker crash). `docker logs` (cli-server stderr) is also saved to
   `out/evidence/stderr.log`. We grep both for `Allowed memory size of <N> bytes exhausted`,
   preferring the `Unknown` line.
2. **Memory high-water mark** — read from the kernel's own counter,
   `/sys/fs/cgroup/memory/memory.max_usage_in_bytes` (cgroup v1; `memory.peak` on v2), while the
   container still exists. This is race-free, unlike polling `docker stats`, which has ~1 s
   latency and misses a sub-second OOM. The container is given a `--memory 1g` ceiling so the
   percentage is meaningful and the kernel does not OOM-kill before PHP's own `memory_limit`.
3. **Container exit state** — `docker inspect … {{.State.Status}} {{.State.ExitCode}}
   {{.State.OOMKilled}}`, captured before teardown. `OOMKilled=false` is expected: this is PHP's
   own `memory_limit` fatal, not a cgroup kill (two different layers — see below).
4. **Liveness** — a `curl` after the probe. 200 = the server kept serving; a connection failure =
   the worker stopped.

## The A/B (observed on this spike)

`morgue-php:vuln` is the deliberately-vulnerable twin (PHP 8.4.10, built with
`docker build --build-arg PHP_TAG=8.4.10-cli -t morgue-php:vuln .`); `morgue-php:local` is the
fixed build (PHP 8.4.27).

| | vulnerable 8.4.10 | fixed 8.4.27 |
|---|---|---|
| memory peak (512M limit, 1g container) | **530 MiB (52%)** — climbs to the limit | **57 MiB (6%)** — bounded |
| `Allowed memory size … exhausted … in Unknown` | **captured** | **absent** |
| scanner verdict | VULNERABLE (in-band fatal while parsing) | FIXED |
| served after probe | HTTP 200 (per-request abort; see below) | HTTP 200 |
| overall verdict / exit | SUSCEPTIBLE / 1 | FIXED / 0 |

The discriminating evidence is the **memory-exhausted fatal and the ~10× memory peak**, nothing
else. Both builds also log an unrelated `PHP Warning: … Multipart body parts limit exceeded 1020
… in Unknown` — that is PHP's pre-existing `max_multipart_body_parts` cap (since 8.0), which fires
on both because the scanner sends >1000 parts; it is **not** the fix and must not be read as one.

## "Suffers an OOM and stops working"

At `memory_limit=512M` under the built-in server, the vulnerable build raises PHP's `memory_limit`
fatal, which **aborts the offending request** (the attacker's operation fails) while the
cli-server process itself recovers and keeps serving — so `served_after` is 200. The OOM event is
nonetheless proven directly: memory climbed to the 512M ceiling and PHP emitted the fatal. Under a
worker-based SAPI (PHP-FPM) or with display suppressed, the same exhaustion kills the worker
(temporary capacity loss) — the vendored scanner's worker-death tier and the Session 4 run. Either
way the request handling dies; we report whichever manifestation we observe rather than forcing a
process crash.

### Layers of "OOM"
- **PHP `memory_limit`** (what we trigger): PHP's accounted allocation hits the configured ceiling
  → the `Allowed memory size … exhausted` fatal. `OOMKilled` stays false.
- **cgroup / kernel OOM-kill**: the container's real RSS hits `--memory` → the kernel SIGKILLs the
  process, `OOMKilled=true`, no PHP fatal. We keep `--memory` above `memory_limit` precisely so the
  PHP layer trips first and we get the textual fatal.

## Fallback: forcing the literal fatal

If a 512M run crashes without flushing the fatal to the log AND the scanner reports VULNERABLE,
`--active` runs one **low-limit evidence pass** at `MEMORY_LIMIT_EVIDENCE` (default 128M) to force
PHP's `memory_limit` fatal to be raised and logged (`Allowed memory size of 134217728 bytes
exhausted …`). This only demonstrates the exhaustion mechanism — a low limit also fatals on a
patched build, so it does **not** by itself distinguish fixed from vulnerable. On this spike the
512M run already captures the fatal, so the fallback stays dormant; it is insurance for other
SAPIs/images. The result JSON records `evidence_pass_memory_limit` when it is used.

## Run it

```
# vulnerable twin: expect SUSCEPTIBLE (exit 1), fatal + ~530 MiB peak
PHP_IMAGE=morgue-php:vuln docs/php84-spike/confirm/confirm-php2shell.sh \
  --active --i-understand-this-crashes-workers

# fixed build: expect FIXED (exit 0), no fatal, bounded memory
docs/php84-spike/confirm/confirm-php2shell.sh --active --i-understand-this-crashes-workers
```

Artifacts land in `docs/php84-spike/confirm/out/` (gitignored): `confirm-*.json` (the verdict +
`oom_evidence`), `scan-*.json` (the scanner's own result), and `evidence/` (`php-error.log`,
`stderr.log`, `stats.log`). The capture never changes the verdict — the runtime-version policy is
authoritative; this only characterises the event.

See `SECURITY-VERIFICATION.md` for the scanner/SBOM before-vs-after and why a runtime-version
policy, not a scanner's silent "0", is the authoritative signal.
