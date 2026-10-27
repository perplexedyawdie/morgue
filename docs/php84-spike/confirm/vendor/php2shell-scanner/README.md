# Vendored: assetnote/php2shell-scanner

A pinned, unmodified copy of the Assetnote PHP2Shell scanner
(CVE-2026-109618 / CVE-2026-109619). Source, commit and license: `NOTICE`, `LICENSE`.

## What it is

- **Detection-only.** It never attempts code execution or a shell, despite the "php2shell" name.
- **Disruptive by design.** It POSTs multipart bodies of 1, 8 and 20 MiB whose field name is a
  PHP array key nested 62 levels deep, and calls a host **vulnerable** when PHP emits an
  out-of-memory fatal (`Allowed memory size … exhausted … Unknown`) or the FPM worker dies
  (empty/502/503/504) versus a normal control response. That can OOM the process or kill workers.
- **Version-aware.** When no crash is seen it falls back to the `X-Powered-By` version against
  `FIXED_VERSIONS = {(8,2):35, (8,3):36, (8,4):27, (8,5):12}` (and treats any branch below 8.2 as
  unfixed). The **first 1 MiB probe is always sent before** that version short-circuit can apply,
  so reading it as non-destructive is wrong.
- Its own README notes it can **false-positive on a patched build** running at a low
  `memory_limit` (the OOM fires for an innocent reason).

## How it is used here

Only through the wrapper, which enforces the safety envelope the tool itself does not:

```
docs/php84-spike/confirm/confirm-php2shell.sh            # version policy only (safe)
docs/php84-spike/confirm/confirm-php2shell.sh --active --i-understand-this-crashes-workers
```

The wrapper refuses any non-loopback target, runs the probe only against a throwaway container it
created, and tears that container down afterward. Do not invoke `scanner.py` directly against
anything you do not own and cannot afford to crash.

## Running the vendored file standalone (for reference)

```
uv run scanner.py -u http://127.0.0.1:PORT -o out.json --all-results
```

`uv` resolves the PEP-723 inline dependencies (`h11`, `tqdm`). The scanner exits 1 only when it
found a *vulnerable* host and 0 otherwise (including inconclusive), and with `-o` it saves only
vulnerable hosts unless `--all-results` is given — the wrapper passes `--all-results` and parses
the JSON rather than trusting the exit code.
