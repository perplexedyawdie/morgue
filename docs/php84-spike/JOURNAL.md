# PHP 7.1 → 8.4.27 upgrade spike — journal

Chronological log of the hand-done upgrade of etsy/morgue to PHP 8.4.27
(the first 8.4 release with the PHP2Shell fix, CVE-2026-109618 / CVE-2026-109619).
Branch: `spike/php84` on `perplexedyawdie/morgue`. Every entry is committed and
pushed as soon as it is written.

Entry format: commands → exact error → root cause → fix → category
(runtime / dependency / framework-vendor / app-code / tests / tooling / infra) → time.

## Environment

### Session 2 (this run, from entry 1 on) — cloud sandbox
- Host: Ubuntu 24.04.5 LTS, linux/amd64 cloud container (claude.ai/code). Root, no sudo needed.
- Host PHP: 8.3.6 (Ubuntu package) and Composer 2.8.12 exist on the host but are NOT used
  for the upgrade itself (wrong minor). Everything runs in containers.
- Docker Engine 29.9.2: client installed, daemon not running at start; started by hand with
  `dockerd &` (overlayfs, cgroup v1). Outbound traffic goes through an HTTPS egress proxy
  with its own CA (`/root/.ccr/ca-bundle.crt`); containers must use `--network host` plus the
  proxy env and CA to reach the network.
- Images: `php:8.4.27-cli` (digest sha256:debadc2e36b8…, `PHP 8.4.27 (cli) (built: Oct 21 2026)`),
  `mariadb:10.4`. Docker Hub returned `429 Too Many Requests` on anonymous pulls twice
  (mariadb:10.4 on first try, composer:2); retrying after ~20 s worked for mariadb.

### Session 1 (entry 0 only) — local
- Host: macOS 27.0 (arm64). No Docker, no native PHP or MySQL on the host.
- Container engine: Podman 6.0.2 (client and server, libkrun machine, linux/arm64).
  Used as a drop-in for `docker` (`podman build`, `podman run`).
- Baseline (PHP 7.1) is NOT reproduced here; it is taken from the earlier
  baseline run (VM + GitLab CI): PHP 7.1 + Composer 2.2 LTS + archive.debian.org
  apt sources, slim/slim 2.6.3, twig/twig 1.43.1, sabre/dav 2.1.11,
  phpunit 6.5.14, MariaDB 10.4, phpunit 11/11 green.

## Entries

### 0. Branch and live documents — 2026-10-27T05:31Z
- `gh repo clone perplexedyawdie/morgue && git checkout -b spike/php84` (from `master`, = etsy/morgue d37ae8c).
- Created this journal and the RUNBOOK.md skeleton.
- First observation while reading `htdocs/index.php`: the Slim app is constructed with
  `'cookies.cipher' => MCRYPT_RIJNDAEL_256` and `MCRYPT_MODE_CBC`. ext/mcrypt is not in the
  official php images (and was removed from core in 7.2). On 7.x an undefined constant is a
  warning ("assumed 'MCRYPT_RIJNDAEL_256'"); on 8.0+ it is a fatal `Error`. Predicted breakage #1,
  which the earlier read-only scan did not list.
- Category: tooling. Time: 5 min.
