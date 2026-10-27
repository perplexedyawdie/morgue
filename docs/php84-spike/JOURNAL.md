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

### 4. Dependencies (composer.json) — 2026-10-27T05:42Z
- New `composer.json`: `php: ">=8.4.27 <8.5"`, `config.platform.php: "8.4.27"`, `slim/slim: 2.6.3`
  (exact; abandoned), `wikimedia/composer-merge-plugin: ^2.1` (was `dev-master`) with
  `config.allow-plugins`, `phpunit/phpunit: ^11` (was `^6`), `twig/twig` **removed**.
  `features/upload/composer.json` (merged in by the plugin): `sabre/dav: ^4.7` (was `~2.1.1`).
  `composer.lock` removed from `.gitignore` so the lock can be committed.
- Twig check: `grep -rni twig` outside composer.json/docs/vendor → 0 hits. Views are plain PHP.
  Removing it also removes 19 Packagist advisories (the step 3 resolution blocker).
- sabre/dav check: only `features/upload/lib/webdav.php` uses it (`use Sabre\DAV\Client`,
  `new Client([...baseUri, userName, password, proxy])`, `->request()` returning
  `statusCode`/`headers`). Same constructor keys and `request()` shape in 4.x.
- Failure 4a: `composer update` resolved fine, then every download failed:
  ```
  Failed to download slim/slim from dist: Could not authenticate against github.com
  Source fallback is disabled. Not trying alternative sources.
  ```
  `curl https://api.github.com/repos/slimphp/Slim/zipball/<sha>` → 403 "GitHub access to this
  repository is not enabled for this session". Root cause: the sandbox egress policy allows
  anonymous **git** reads of public GitHub repos but not GitHub **API** zipball downloads,
  which is where Packagist points every dist. A token in `COMPOSER_AUTH` did not help (policy,
  not auth). Fix: `composer install --prefer-source` (git clones through the proxy, with
  `GIT_SSL_CAINFO` for the proxy CA). Much slower (full `git clone --mirror` per package,
  ~5 min for 29 packages), so the harness now keeps the Composer cache in a named volume
  (`morgue-composer-cache`) and only falls back to `--prefer-source` when the dist error
  appears. Category: infra. Time: 8 min.
- Failure 4b (observed in the lock): first `composer update` produced a lock WITHOUT
  `sabre/dav`. Root cause: composer-merge-plugin was not installed yet when the root package
  was resolved, so `features/upload/composer.json` was never merged. Fix: run
  `composer update` a second time once the plugin is installed. Category: dependency.
- Failure 4c: during that first `composer install --prefer-source` (6 min), the merge plugin
  ran its own follow-up update after it was installed and added `sabre/*` to the lock,
  but that nested update ignored `--prefer-source` and failed the same way as 4a
  (`Failed to download sabre/dav from dist`). Fix: run `composer install --prefer-source`
  again against the now-complete lock (9 s with the cache volume). Category: tooling. 2 min.
- Resolved lock (committed): prod `slim/slim 2.6.3`, `sabre/dav 4.7.1` (+ sabre/http 5.1.13,
  event 5.1.9, uri 2.3.4, vobject 4.6.1, xml 2.2.11, psr/log 3.0.2),
  `wikimedia/composer-merge-plugin v2.1.0`; dev `phpunit/phpunit 11.5.57` + 26 sebastian/phar-io/etc.
  `composer audit` → "No security vulnerability advisories found". `composer validate` reports no
  stale lock (only name/description/license warnings).
- Gap: `composer audit --abandoned=report` does NOT flag Slim 2: the package name `slim/slim` is
  alive (v4), only its 2.x line is dead. Abandonment has to be judged per major line.
- Slim 2 / `get_magic_quotes_gpc()` strategy, option 1 (app-level polyfill loaded before Slim):
  `phplib/compat/slim2_php8.php`, registered in `composer.json` `autoload.files` so it runs at
  `require 'vendor/autoload.php'`. It defines `get_magic_quotes_gpc()` (returns false) and the
  `MCRYPT_RIJNDAEL_256` / `MCRYPT_MODE_CBC` constants (static scan P2), all guarded. Unqualified
  calls inside `namespace Slim\Http` fall back to the global function, so no vendor edit is
  needed. Whether it suffices is decided in step 5.
- Category: dependency. Time: 15 min (most of it waiting on git clones).

### 5. Fix loop
Harness at `error_reporting=E_ALL`, display_errors + log_errors on.

#### 5.1 Slim 2 vendor deprecations are fatal under Slim's own error handler — 05:59Z
- Command: `SKIP_BUILD=1 docs/php84-spike/harness/run.sh` (first full run on the new deps).
- Error: `GET /ping` body starts with `Deprecated: Return type of Slim\Helper\Set::offsetExists($offset)
  should either be compatible with ArrayAccess::offsetExists(mixed $offset): bool, or the
  #[\ReturnTypeWillChange] attribute should be used …`; PHP log (90 lines) has
  `PHP Fatal error: During inheritance of ArrayAccess: Uncaught ErrorException: Return type of
  Slim\Http\Response::offsetExists($offset) …` and then `session_set_save_handler(): Session save
  handler cannot be changed after headers have already been sent` warnings; `POST /events`
  returned 200 instead of a redirect.
- Root cause: `Slim::run()` (Slim.php:1291) installs `Slim::handleErrors()`, which throws
  `ErrorException` for every level enabled in `error_reporting()` (Slim.php:1404-1411). Slim
  2.6.3's own PHP 8.1 deprecations (ArrayAccess/Countable/IteratorAggregate without return
  types) and its 8.4 deprecation (`session_set_save_handler()` with callables,
  SessionCookie.php:94) therefore become fatal, not just noisy. Classes loaded before `run()`
  only print the deprecation; that early output then breaks `session_*()` header calls.
- Fix (runtime config only, as allowed for vendor code): `docker/php/morgue.ini` → baked into
  the image as `conf.d/zz-morgue.ini`: `error_reporting = E_ALL & ~E_DEPRECATED`,
  display_errors Off, log_errors On. The harness server uses the same level; phpunit keeps
  full `E_ALL` (tests load only app code). The harness now also fails on Slim's
  "Slim Application Error" page.
- **Accepted vendor deprecations (slim/slim 2.6.3, suppressed by the line above)**, enumerated
  by loading every class under `vendor/slim/slim/Slim` at E_ALL (23 compile-time + 1 runtime):
  1. `Slim\Helper\Set::{offsetExists,offsetGet,offsetSet,offsetUnset,getIterator,count}` — 8.1
     tentative return types (also covers `Http\Headers`, `Http\Cookies`, which extend Set)
  2. `Slim\Environment::{offsetExists,offsetGet,offsetSet,offsetUnset,getIterator}` — 8.1
  3. `Slim\Http\Response::{offsetExists,offsetGet,offsetSet,offsetUnset,getIterator,count}` — 8.1
  4. `Slim\Middleware\Flash::{offsetExists,offsetGet,offsetSet,offsetUnset,getIterator,count}` — 8.1
  5. `Slim\Middleware\SessionCookie::call()` line 94: `session_set_save_handler()` with
     individual callbacks — 8.4 (runtime, every request)
- Side effect to know about: with Slim's handler in place, `~E_DEPRECATED` also silences app
  deprecations at runtime in the web path (the handler returns without logging). App
  deprecations are therefore hunted with phpunit at E_ALL, `php -l` and the static scan instead.
- Slim strategy result: **option 1 (app-level polyfill) works.** `get_magic_quotes_gpc()` and
  the mcrypt constants are resolved from `phplib/compat/slim2_php8.php` (`POST /events` read its
  input and the row was persisted). Options 2 (composer-patches) and 3 (fork) were not needed;
  they would only be required to *fix* (rather than suppress) the deprecations above, or if a
  removed function were called fully-qualified or a removed class/syntax were used.
- After the fix: /ping, /, POST /events, DB row PASS; `GET /events/1` → 500 (5.2); phpunit
  fatal (5.3).
- Category: framework-vendor. Time: 6 min.

#### 5.2 Slack API response read on null → 500 on every event page — 06:03Z
- Command: harness run after 5.1.
- Error: `GET /events/1 -> 500`, body "Slim Application Error … Type: ErrorException Code: 2
  Message: Attempt to read property "ok" on null File: /app/features/slack/lib.php Line: 77",
  called from `features/slack/views/slack.php:13` (edit page includes every enabled feature).
- Root cause: the event page calls `https://slack.com/api/channels.list` on every render;
  with no reachable API (the harness app container has no egress), `json_decode(false)` is
  null. PHP 8.0 promoted "Trying to get property of non-object" from E_NOTICE to E_WARNING
  ("Attempt to read property … on null"), and Slim's handler turns it into an exception. The 7.1
  baseline only passed because its CI could reach slack.com, which answered with JSON
  (`ok:false`).
- Fix (app code): `features/slack/lib.php:42,77,126` → `empty($x->ok)` / `!empty($data->ok)`,
  which is null-safe and silent.
- After: all 7 smoke checks PASS; phpunit still fatal (5.3).
- Category: app-code. Time: 4 min.

#### 5.3 PHPUnit 11: `setUp()` must return `void` — 06:05Z
- Command: harness run after 5.2 (phpunit step).
- Error: `PHP Fatal error: Declaration of CurlClientTest::setUp() must be compatible with
  PHPUnit\Framework\TestCase::setUp(): void in /app/tests/unit/CurlClient_Test.php on line 8`.
  Note it fatals although the `--filter` excludes CurlClient: PHPUnit loads every test file
  before it filters.
- Root cause: PHPUnit 8+ declares `protected function setUp(): void`.
- Fix: `tests/unit/{CurlClient,JiraClient}_Test.php` → `protected function setUp(): void`.
- After: `Class Contact_Test cannot be found in /app/tests/unit/Contact_Test.php` (×3),
  `No tests executed!` (5.4); `PHP Deprecated: CurlClient::get(): Implicitly marking parameter
  $params as nullable` (5.5).
- Category: tests. Time: 2 min.

#### 5.4 PHPUnit 10+: test class must match its file name — 06:06Z
- Error: `There were 3 PHPUnit test runner warnings: 1) Class Contact_Test cannot be found in
  /app/tests/unit/Contact_Test.php` … `No tests executed!` (exit 1).
- Root cause: PHPUnit 10 dropped the "find any TestCase subclass in the file" fallback; the
  class (`ContactTest`) must be named like the file (`Contact_Test.php`).
- Fix: `git mv tests/unit/{Contact,CurlClient,JiraClient}_Test.php → …Test.php` (keeps the
  `*Test.php` suffix the directory scan needs; nothing else referenced the old names).
- After: `Tests: 7, Assertions: 7, Errors: 2, Deprecations: 8, PHPUnit Deprecations: 2`:
  TypeError from `implode()` (5.5), non-static data provider (5.6), deprecations (5.7, 5.8).
- Category: tests. Time: 2 min.

#### 5.5 `implode()` with reversed arguments → TypeError (predicted P4) — 06:08Z
- Error: `JiraClientTest::test_getJiraApiResponse_withTickets  TypeError: implode(): Argument #1
  ($separator) must be of type string, array given  /app/features/jira/lib.php:223`.
- Root cause: `implode($pieces, $glue)` was deprecated in 7.4 and removed in 8.0. Found by the
  static scan; the earlier read-only grep had missed it. Not on the smoke path (JIRA lookups
  only run when an event has tickets), so only the unit test catches it at runtime.
- Fix: `features/jira/lib.php:223,225` → `implode('","', $jira_key_input)`, `implode(',', $fields)`.
- After: `Tests: 7, Assertions: 12, Errors: 1, Deprecations: 8, PHPUnit Deprecations: 2`.
- Category: app-code. Time: 2 min.

#### 5.6 PHPUnit 11 API: static data providers, attributes, `willReturn`, declared props — 06:10Z
- Command: `vendor/bin/phpunit --include-path=phplib --filter '/^(?!.*CurlClient)/'
  --display-deprecations --display-phpunit-deprecations tests/unit/` (at E_ALL).
- Errors: `The data provider specified for JiraClientTest::test_unpackTicketInfo is invalid. Data
  Provider method JiraClientTest::provideTicketsFieldsRequirements() is not static` (error, so
  its 4 cases never ran); `Metadata found in doc-comment … deprecated and will no longer be
  supported in PHPUnit 12`; `returnValue() is deprecated and will be removed in PHPUnit 12`;
  `Creation of dynamic property JiraClientTest::$curl_client / $jira_client is deprecated` (8.2).
- Root cause: PHPUnit 10 requires static providers and moved metadata to attributes; PHP 8.2
  deprecates undeclared properties, including on test classes.
- Fix (tests only): `JiraClientTest.php` → `public static function provideTicketsFieldsRequirements()`,
  `#[DataProvider('provideTicketsFieldsRequirements')]` instead of `@dataProvider`,
  `->willReturn(...)` instead of `->will($this->returnValue(...))`, `createMock('CurlClient')`
  (the 2nd arg was the PHPUnit 5 `setMethods` list, ignored since 6), declared
  `private $curl_client, $jira_client`; `CurlClientTest.php` → declared `private $curl_client`.
  Done to PHPUnit 12-ready level so the next major isn't another migration.
- After: `OK, but there were issues! Tests: 11, Assertions: 16, Deprecations: 6` — the 11 tests
  match the 7.1 baseline count; remaining deprecations are app code (5.7, 5.8).
- Category: tests. Time: 3 min.

#### 5.7 JiraClient dynamic properties (8.2) — 06:13Z
- Error (phpunit, E_ALL): `Creation of dynamic property JiraClient::$curl_client is deprecated`
  (+ `$jira_base_url`, `$username`, `$password`, `$proxy`, `$additional_fields`), features/jira/lib.php:180-190.
- Root cause: PHP 8.2 deprecates writing undeclared properties.
- Sweep: because the web path runs with `~E_DEPRECATED` (5.1), a tokenizer script
  (`$this->x =` writes vs declared properties, every class in htdocs/phplib/features/views/tests)
  was run to find the ones no test reaches: also `Uploader_Webdav::$client`
  (features/upload/lib/webdav.php:38) and 9 properties of `Calendar` (features/calendar/lib.php:8-20,
  rendered on every event page) → 5.8.
- Fix: declared the six as `private` in `JiraClient` (grep: nothing outside the class reads them).
- After: `OK (11 tests, 16 assertions)`; one compile-time deprecation left on stderr (5.9).
- Category: app-code. Time: 4 min.

#### 5.8 Calendar / Uploader_Webdav dynamic properties (found by the sweep, not by tests) — 06:16Z
- Error (CLI repro at E_ALL; the web path hides it): `Creation of dynamic property
  Calendar::$clientId is deprecated` … for 9 properties written in `Calendar::__construct()`,
  and `Uploader_Webdav::$client` in `create_client()`.
- Root cause: PHP 8.2 dynamic-property deprecation; no unit test covers these classes and the
  web path runs with `~E_DEPRECATED`, so only the static sweep found them.
- Fix: `features/calendar/lib.php` declares the 9 as `public` (the calendar views read them);
  `features/upload/lib/webdav.php` declares `private $client`.
- Verification: sweep script → no findings; CLI at `error_reporting(E_ALL)`:
  `new Calendar` → "Calendar ok: CLIENTID", `new Uploader_Webdav([...])` → OK, which also shows
  sabre/dav 4.7.1's `Sabre\DAV\Client` accepts the 2.1-era settings array (baseUri, userName,
  password, proxy).
- Category: app-code. Time: 4 min.

#### 5.9 Implicitly nullable parameter (8.4, predicted P5) — 06:18Z
- Error: `PHP Deprecated: CurlClient::get(): Implicitly marking parameter $params as nullable is
  deprecated, the explicit nullable type must be used instead in /app/phplib/CurlClient.php on line 5`
  (compile time, printed on every phpunit run and every request that loads CurlClient).
- Root cause: PHP 8.4 deprecates `array $x = null`; the type must say `?array`.
- Fix: `phplib/CurlClient.php:5` → `?array $params = null`. Same accepted values as before.
- Verification: `php -d error_reporting=E_ALL -l phplib/CurlClient.php` → "No syntax errors", no deprecation.
- Category: app-code. Time: 1 min.
