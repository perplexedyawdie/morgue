# PHP 7.1 → 8.4.27 upgrade spike — journal

Chronological log of the hand-done upgrade of etsy/morgue to PHP 8.4.27
(the first 8.4 release with the PHP2Shell fix, CVE-2026-109618 / CVE-2026-109619).
Branch: `spike/php84` on `perplexedyawdie/morgue`. Every entry is committed and
pushed as soon as it is written.

Times are wall-clock, taken from commit timestamps (session 2 started 05:33Z).

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

### 1. Acceptance harness — 2026-10-27T05:36Z
- Added `docs/php84-spike/harness/run.sh` (one command: `docs/php84-spike/harness/run.sh`).
  Steps: build the repo-root `Dockerfile` → `php -v` + runtime policy (`PHP_VERSION >= 8.4.27`)
  + `pdo_mysql` loaded → `composer install` → MariaDB 10.4 container on host network, schemas
  loaded as postmortems.sql → other top-level schemas → anniversary.sql (migrations/ skipped)
  → `config/development.json` generated from `example.json` (mysqlhost 127.0.0.1, port 33306)
  → README dev server (`php -S`, `MORGUE_ENVIRONMENT=development`,
  `include_path=.:/app:/app/features`) with `error_reporting=E_ALL`, display + log errors on
  → smoke: `GET /ping` = `{"status":"ok"}`, `GET /` = 200, `POST /events` with every NOT NULL
  field → 302 to `/events/<id>`, `GET /events/<id>` = 200 and shows the title, row present in
  `postmortems`, no PHP error text in any response body, PHP error log has no
  Fatal/Parse/Warning/Notice/Deprecated lines → phpunit (`--include-path=phplib`,
  `--filter '/^(?!.*CurlClient)/'`).
- Design choices: all PHP runs in the image (host PHP 8.3 never used); `--network host` so
  the egress proxy on 127.0.0.1 is reachable, and the host's `HTTPS_PROXY` + `SSL_CERT_FILE`
  are passed in when set; outputs go to `harness/out/` (gitignored).
- Not yet runnable: the Dockerfile arrives in step 3. Deprecations are treated as failures
  unless suppressed through `ERROR_REPORTING` (runtime config), which keeps any accepted
  vendor deprecation explicit.
- Category: tooling. Time: 3 min.

### 2. Static compatibility scan (no code changed) — 2026-10-27T05:39Z
- Commands (all in `php:8.4.27-cli`): `php -l` on all 88 non-vendor PHP files; phpcs 3 +
  `phpcompatibility/php-compatibility` **10.0.0-alpha2** (`--runtime-set testVersion 8.4`)
  over htdocs, phplib, features, views, tests; the same phpcs run over `slim/slim` 2.6.3
  fetched into a scratch dir (vendor is where the known blocker lives, so scan it too).
- Results saved in `docs/php84-spike/static-scan.txt`, section E = predicted breakage list.
- App: 0 parse errors. Errors: mcrypt constants (index.php:28-29), reversed `implode()` args
  (features/jira/lib.php:223,225 → TypeError in 8.0, contradicting the earlier read-only scan's
  "no removed functions in app code"). Deprecations: implicit nullable (CurlClient.php:5),
  optional-before-required (Persistence.php:230), `E_USER_ERROR` (Persistence.php:251),
  `${var}` interpolation (anniversary-mail.php:29).
- Slim 2.6.3: `get_magic_quotes_gpc()` (Util.php:60) as expected, **plus** mcrypt constants
  in `Slim::getDefaultSettings()` (Slim.php:306-307) — evaluated on every `new \Slim\Slim()`,
  so a polyfill must define the constants as well, not just the function. Also 8.4
  `session_set_save_handler()` callable-form deprecation in `SessionCookie`, which
  index.php:95 adds on every request.
- Tooling note: PHPCompatibility 9.3.5 (the last stable, 2019) has no PHP 8.1–8.4 sniffs; only
  the 10.0 alpha found the 8.2/8.4 items. Static scans can't see dependency-resolution
  failures, PHPUnit API changes or dynamic-property/null-to-string runtime deprecations.
- Behavioural finding: Slim 2's cookie `encrypt()` is a no-op when ext/mcrypt is absent, and
  the 7.1 image had no mcrypt, so `cookies.encrypt => true` never encrypted anything.
- Category: tooling. Time: 3 min.

### 3. Runtime: Dockerfile for PHP 8.4.27 — 2026-10-27T05:40Z
- Added repo-root `Dockerfile`: `FROM php:8.4.27-cli` (exact patch pin), `git` + `unzip`
  (Composer needs one of unzip/ext-zip to extract dists), `docker-php-ext-install pdo_mysql`,
  `COPY --from=composer:2.10.3` (latest Composer 2 on 2026-10-27), `COMPOSER_ALLOW_SUPERUSER=1`.
  None of the 7.1 shims are needed: trixie is a supported Debian, Composer 2 is current.
  Added `.dockerignore` (vendor, .git, harness output) and `docker/extra-ca/` for an optional
  proxy CA; the harness passes `HTTPS_PROXY` as a build arg and drops `$SSL_CERT_FILE` there.
- Failure 3a: `docker build` → `failed to resolve source metadata for
  docker.io/library/composer:2.10.3: … 429 Too Many Requests`. Root cause: anonymous Docker
  Hub pull rate limit (shared sandbox egress IP). Fix: pulled `composer:2` once (succeeded on
  retry, = 2.10.3) and `docker tag composer:2 composer:2.10.3` locally. Category: infra. 1 min.
- Failure 3b: `apt-get update` in a container → `Could not resolve 'deb.debian.org'`. Root
  cause: the sandbox allows only HTTPS via its proxy. Fix: Dockerfile rewrites apt sources to
  `https://deb.debian.org` and trusts `docker/extra-ca/*.crt`; build uses `--network host`
  and `--build-arg HTTPS_PROXY`. Category: infra. 1 min.
- Verified: `php -v` → `PHP 8.4.27 (cli) (built: Oct 21 2026 15:53:07) (NTS)`; `pdo_mysql`
  loaded; `Composer version 2.10.3 2026-08-27`.
- First harness run on 8.4.27 with the UNCHANGED composer.json → RED at `composer install`:
  ```
  Root composer.json requires twig/twig 1.*, found twig/twig[1.3.0, ..., v1.44.8] but these
  were not loaded, because they are affected by security advisories ("PKSA-8zx5-v2nz-58pb", …
  19 advisories)
  Root composer.json requires phpunit/phpunit ^6, found phpunit/phpunit[6.0.0, ..., 6.5.14]
  but these were not loaded, because they are affected by security advisories ("PKSA-z3gr-8qht-p93v")
  ```
  Root cause: recent Composer 2 releases enable `policy.advisories.block` by default and drop
  any version with a Packagist security advisory during resolution. It fails before any PHP
  version constraint is even considered. This is new compared with the 7.1 baseline (Composer
  2.2 LTS, which only audits after install). It is handled by step 4 (remove Twig, move PHPUnit).
  Category: dependency. 1 min.
- Category: runtime. Time: 4 min total.
