---
name: confirm-php2shell
description: >-
  Confirm whether a local, disposable morgue runtime image is susceptible to PHP2Shell
  (CVE-2026-109618 / CVE-2026-109619) before and after the PHP upgrade. Authorized self-test of
  your own containers only. Triggers: PHP2Shell, CVE-2026-109618, CVE-2026-109619, confirm/verify
  PHP RCE exposure, "is this still vulnerable", PHP OOM multipart RCE, prove the 8.4.27 upgrade
  closed the finding.
license: "MIT AND CC-BY-SA-4.0"
compatibility: "Requires docker and uv; reads PHP_VERSION from the image and (optionally) runs the vendored assetnote scanner."
allowed-tools:
  - "Bash(docs/php84-spike/confirm/confirm-php2shell.sh:*)"
  - "Bash(docker:*)"
  - "Bash(curl:*)"
  - "Bash(uv:*)"
  - "Read"
---

# Confirm PHP2Shell exposure (CVE-2026-109618 / CVE-2026-109619)

Confirms whether a morgue runtime **image you built** is susceptible to PHP2Shell, and proves the
8.4.27 upgrade closed it. This operationalizes RUNBOOK **WI-2** ("detect and confirm exposure")
and supports **WI-9** (security re-verification) as a one-command, reproducible check.

The authoritative signal is the non-destructive runtime-version policy. An opt-in active probe
(the vendored Assetnote scanner's out-of-memory differential) only corroborates it.

## When to use

- Before the upgrade: show the current image is **SUSCEPTIBLE**.
- After the upgrade: show the fixed image is **FIXED** (pairs with `SECURITY-VERIFICATION.md`).
- In CI, as a gate that fails if an image regresses to a vulnerable or end-of-life PHP.

## The one command

```
docs/php84-spike/confirm/confirm-php2shell.sh                 # Layer 1 only (safe, default)
PHP_IMAGE=morgue-php:vuln docs/php84-spike/confirm/confirm-php2shell.sh
docs/php84-spike/confirm/confirm-php2shell.sh --active --i-understand-this-crashes-workers
```

Inputs (env / flags):
- `PHP_IMAGE` (default `morgue-php:local`) — the image under test.
- `--active` + `--i-understand-this-crashes-workers` — run the disruptive probe (both required).
- `--memory-limit` (default `512M`) — set on the target so a *patched* build completes and the
  scanner's low-memory false positive does not fire.
- `--port` (default `8099`) — loopback port the script publishes.

Output — one verdict, written to `confirm/out/confirm-*.json` (gitignored) and the exit code:

| Verdict | Exit | Meaning |
|---|---|---|
| `FIXED` | 0 | runtime ≥ the fixed release on its branch |
| `SUSCEPTIBLE` | 1 | below the fixed patch, or on an end-of-life branch |
| `INCONCLUSIVE` | 2 | version unreadable, misuse, or a guardrail refusal |

## Confirmation contract

**Layer 1 — runtime-version policy (always; non-destructive).**
Read the PHP version two ways and apply the per-branch fixed-release map plus an end-of-life rule.
- Authoritative: `docker run --rm <image> php -r 'echo PHP_VERSION;'`.
- Black-box: `X-Powered-By` from a short-lived loopback morgue server (reports if `expose_php=Off`).
- `FIXED_VERSIONS = {8.2: 35, 8.3: 36, 8.4: 27, 8.5: 12}` (identical to the scanner and the runbook).
  A version below its branch's floor, **or a branch not in the map (EOL)**, is SUSCEPTIBLE.

**Layer 2 — active OOM probe (opt-in `--active`; disruptive; local disposable only).**
Run the vendored scanner against a minimal PHP endpoint served from the same image on loopback.
PHP2Shell lives in PHP's multipart parser, not in morgue, so a minimal endpoint exercises the
exact runtime without the app's committed lock (`platform_check.php`) refusing an older PHP before
the request runs. The probe streams 1/8/20 MiB bodies with a 62-deep nested array key and calls
the runtime vulnerable when it OOMs or the worker dies versus a healthy control. Because it crashes
the worker, the script uses a **fresh container it created and destroys afterward**. The version
policy remains the verdict; the probe is corroboration, and disagreement is reported.

## Hard guardrails (enforced in the wrapper, not advice)

- **Loopback only.** There is no `--url`. The script starts the target itself and talks to
  `127.0.0.1:<port>` it published. A non-loopback host is refused before anything is sent.
- **`--active` is gated.** It requires `--i-understand-this-crashes-workers` and prints that it
  will crash the worker on a disposable target.
- **Layer 1 never sends a probe.** The skill escalates no further than detection — no shell, no
  payload beyond the upstream OOM probe, which is a denial-of-service differential and **not** an
  exploit. It proves susceptibility, not code execution.
- The probe is only ever pointed at a container this script started and tears down.

## Build the images for an A/B check

```
# Fixed (default build):
docs/php84-spike/harness/run.sh            # builds morgue-php:local (PHP 8.4.27)

# Deliberately-vulnerable twin (for demonstrating the probe fires; never deploy it):
docker build --build-arg PHP_TAG=8.4.10-cli -t morgue-php:vuln .
```

## Acceptance

- `confirm-php2shell.sh` on the fixed image → **FIXED**, exit 0; with `--active`, the scanner
  reports no crash.
- `PHP_IMAGE=morgue-php:vuln … confirm-php2shell.sh` → **SUSCEPTIBLE**, exit 1; with `--active`,
  the scanner crashes the worker and reports VULNERABLE.
- A non-loopback target, or `--active` without the confirmation flag → exit 2, nothing sent.

## Example (morgue)

Recorded in `JOURNAL.md` "Session 4" and consistent with `SECURITY-VERIFICATION.md` (Grype saw
CVE-2026-109619 on 7.1.33; Trivy was blind to source-built PHP — a scanner's silent "0" is not a
pass, which is why the verdict is a version policy, corroborated here by the runtime probe).

## Provenance and reuse

- The detector is `vendor/php2shell-scanner/scanner.py`, a pinned verbatim copy of
  `github.com/assetnote/php2shell-scanner` @ `052b56e` (MIT; see `vendor/.../NOTICE`, `LICENSE`).
  No novel exploit code was written; the skill drives the vetted upstream tool.
- The parallel-agent briefing in `RUNBOOK.md` ("Running work items with parallel agents") adapts
  `references/multi-agent-pitfalls.md` from `github.com/netresearch/php-modernization-skill`
  (CC-BY-SA-4.0), hence the dual license above.
- Reuses `../harness/run.sh` (to build/run the app) and `../harness/policy-php-version.sh` (the
  single-floor image gate); this skill implements the full per-branch + EOL policy in the wrapper.
