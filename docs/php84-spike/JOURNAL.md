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
- Commands (all in `php:8.4.27-cli`): `php -l` on all 85 non-vendor PHP files; phpcs 3 +
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

### 4. Dependencies (composer.json) — 2026-10-27T05:42Z → 05:58Z
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
  appears. Category: infra.
- Failure 4b (observed in the lock): first `composer update` produced a lock WITHOUT
  `sabre/dav`. Root cause: composer-merge-plugin was not installed yet when the root package
  was resolved, so `features/upload/composer.json` was never merged. Fix: run
  `composer update` a second time once the plugin is installed. Category: dependency.
- Failure 4c: during that first `composer install --prefer-source` (6 min), the merge plugin
  ran its own follow-up update after it was installed and added `sabre/*` to the lock,
  but that nested update ignored `--prefer-source` and failed the same way as 4a
  (`Failed to download sabre/dav from dist`). Fix: run `composer install --prefer-source`
  again against the now-complete lock (9 s with the cache volume). Category: tooling.
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
- Category: dependency. Time: 16 min wall-clock (05:42–05:58), ~12 of it waiting on git clones.

### 5. Fix loop
Harness at `error_reporting=E_ALL`, display_errors + log_errors on.

#### 5.1 Slim 2 vendor deprecations are fatal under Slim's own error handler — 06:00Z
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
  by loading every class under `vendor/slim/slim/Slim` at E_ALL (23 compile-time) plus the 5.15 audit (2 runtime):
  1. `Slim\Helper\Set::{offsetExists,offsetGet,offsetSet,offsetUnset,getIterator,count}` — 8.1
     tentative return types (also covers `Http\Headers`, `Http\Cookies`, which extend Set)
  2. `Slim\Environment::{offsetExists,offsetGet,offsetSet,offsetUnset,getIterator}` — 8.1
  3. `Slim\Http\Response::{offsetExists,offsetGet,offsetSet,offsetUnset,getIterator,count}` — 8.1
  4. `Slim\Middleware\Flash::{offsetExists,offsetGet,offsetSet,offsetUnset,getIterator,count}` — 8.1
  5. `Slim\Middleware\SessionCookie::call()` line 94: `session_set_save_handler()` with
     individual callbacks — 8.4 (runtime, every request)
  6. `Slim\Http\Util::parseCookieHeader()`-path, Util.php:401: `rtrim(null)` — 8.1 null to
     non-nullable internal parameter (runtime, every request; found later by the 5.15 audit)
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
- Category: framework-vendor. Time: 2 min.

#### 5.2 Slack API response read on null → 500 on every event page — 06:01Z
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
- Category: app-code. Time: 1 min.

#### 5.3 PHPUnit 11: `setUp()` must return `void` — 06:02Z
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
- Category: tests. Time: 1 min.

#### 5.4 PHPUnit 10+: test class must match its file name — 06:02Z
- Error: `There were 3 PHPUnit test runner warnings: 1) Class Contact_Test cannot be found in
  /app/tests/unit/Contact_Test.php` … `No tests executed!` (exit 1).
- Root cause: PHPUnit 10 dropped the "find any TestCase subclass in the file" fallback; the
  class (`ContactTest`) must be named like the file (`Contact_Test.php`).
- Fix: `git mv tests/unit/{Contact,CurlClient,JiraClient}_Test.php → …Test.php` (keeps the
  `*Test.php` suffix the directory scan needs; nothing else referenced the old names).
- After: `Tests: 7, Assertions: 7, Errors: 2, Deprecations: 8, PHPUnit Deprecations: 2`:
  TypeError from `implode()` (5.5), non-static data provider (5.6), deprecations (5.7, 5.8).
- Category: tests. Time: <1 min.

#### 5.5 `implode()` with reversed arguments → TypeError (predicted P4) — 06:03Z
- Error: `JiraClientTest::test_getJiraApiResponse_withTickets  TypeError: implode(): Argument #1
  ($separator) must be of type string, array given  /app/features/jira/lib.php:223`.
- Root cause: `implode($pieces, $glue)` was deprecated in 7.4 and removed in 8.0. Found by the
  static scan; the earlier read-only grep had missed it. Not on the smoke path (JIRA lookups
  only run when an event has tickets), so only the unit test catches it at runtime.
- Fix: `features/jira/lib.php:223,225` → `implode('","', $jira_key_input)`, `implode(',', $fields)`.
- After: `Tests: 7, Assertions: 12, Errors: 1, Deprecations: 8, PHPUnit Deprecations: 2`.
- Category: app-code. Time: <1 min.

#### 5.6 PHPUnit 11 API: static data providers, attributes, `willReturn`, declared props — 06:03Z
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
- Category: tests. Time: 1 min.

#### 5.7 JiraClient dynamic properties (8.2) — 06:04Z
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
- Category: app-code. Time: 1 min.

#### 5.8 Calendar / Uploader_Webdav dynamic properties (found by the sweep, not by tests) — 06:05Z
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
- Category: app-code. Time: 1 min.

#### 5.9 Implicitly nullable parameter (8.4, predicted P5) — 06:05Z
- Error: `PHP Deprecated: CurlClient::get(): Implicitly marking parameter $params as nullable is
  deprecated, the explicit nullable type must be used instead in /app/phplib/CurlClient.php on line 5`
  (compile time, printed on every phpunit run and every request that loads CurlClient).
- Root cause: PHP 8.4 deprecates `array $x = null`; the type must say `?array`.
- Fix: `phplib/CurlClient.php:5` → `?array $params = null`. Same accepted values as before.
- Verification: `php -d error_reporting=E_ALL -l phplib/CurlClient.php` → "No syntax errors", no deprecation.
- Category: app-code. Time: <1 min.

#### 5.10 `Persistence::get_array()`: optional-before-required (8.0) and `E_USER_ERROR` (8.4) — 06:05Z
- Error: `PHP Deprecated: Persistence::get_array(): Optional parameter $where declared before
  required parameter $table_name is implicitly treated as a required parameter in
  /app/phplib/Persistence.php on line 230` (compile time); static scan P7: `Passing E_USER_ERROR
  to trigger_error() is deprecated since 8.4` (line 251).
- Root cause: the `= array()` default on `$where` was never usable (8 callers all pass 4 args,
  some pass `null`, which the body already normalises); 8.4 deprecates `E_USER_ERROR`.
- Fix: drop the dead default (`$where` without default, same effective signature);
  `trigger_error(..., E_USER_ERROR)` → `throw new InvalidArgumentException(...)`. Same outcome
  as before: under Slim's handler E_USER_ERROR already became a thrown ErrorException; outside
  Slim both halt the script.
- Verification: `php -d error_reporting=E_ALL -l phplib/Persistence.php` → clean.
- Category: app-code. Time: <1 min.

#### 5.11 `${var}` string interpolation (8.2, predicted P8) — 06:05Z
- Error: `Deprecated: Using ${var} in strings is deprecated, use {$var} instead in
  ./features/anniversary/views/anniversary-mail.php on line 29` (php -l, compile time).
- Fix: `"<h3>${subject}</h3>"` → `"<h3>{$subject}</h3>"`. Identical output.
- Verification: `php -d error_reporting=E_ALL -l` → clean.
- Category: app-code. Time: <1 min.

#### 5.12 App's own mcrypt constants (predicted P1) — 06:06Z
- Finding: `htdocs/index.php:28-29` passed `MCRYPT_RIJNDAEL_256` / `MCRYPT_MODE_CBC` to Slim. Not
  failing any more (the polyfill from step 4 defines them), but the app should not depend on a
  removed extension's constants.
- Fix: removed the two `cookies.cipher*` settings (Slim's defaults are the same values) and
  documented that `cookies.encrypt` is a no-op without ext/mcrypt (it already was on 7.1).
- After: **HARNESS GREEN** — /ping, /, POST /events → /events/1, GET /events/1 shows the title,
  row persisted, no PHP error text, PHP log clean; `OK (11 tests, 16 assertions)` at E_ALL.
- Category: app-code. Time: 1 min.

#### 5.13 Unknown event id → 500 instead of 404 (found by crawling every GET route) — 06:07Z
- Command: harness with `KEEP=1`, then `curl` over all 27 GET routes from `htdocs/index.php` and
  `features/*/routes.php` with a real id (1) and a missing id (999), grepping for Slim error pages.
  All real-id routes → 200/302 (`/events/1/channels` 404 is the disabled irc feature).
- Error: `GET /events/999` → 500 "ErrorException Code: 2 Message: Trying to access array offset
  on false File: /app/phplib/Postmortem.php Line: 85".
- Root cause: `Persistence::get_postmortem()` returns `PDOStatement::fetch()`'s `false` when no
  row exists; callers do `$event["id"]`. Array access on bool was silent until 7.4 (notice) and
  is an E_WARNING since 8.0, which Slim turns into an exception. Second factor: PHP 8 changed the
  built-in default `error_reporting` (no php.ini, as in the docker images) from
  `E_ALL & ~E_NOTICE & ~E_STRICT & ~E_DEPRECATED` to `E_ALL`, so even the 7.4-era notices would now
  reach Slim's handler.
- Fix: `get_postmortem()` returns its documented error shape `array("id" => null, "error" => …)`
  when the row is missing. Both callers already handle `id === null`.
- After: `/events/999`, `/events/999/{summary,tldr,why_surprised}` → 404.
- Category: app-code. Time: 1 min.

#### 5.14 Unknown id on `/events/:id/lock` and `/history/:event_id/:history_id` → 500 — 06:07Z
- Errors (route crawl): `GET /events/999/lock` → 500 "Undefined array key "created" File:
  /app/phplib/Postmortem.php Line: 142"; `GET /history/999/999` → 500 "Undefined array key
  "create_date" File: /app/features/history/routes.php Line: 10".
- Root cause: undefined index went from E_NOTICE (filtered out by the 7.x default error_reporting)
  to E_WARNING in 8.0. Also hidden: `get_history_event()` did `$history = false; $history["status"]
  = OK`, i.e. false-to-array autovivification, deprecated in 8.1 (silenced on the web path). On 7.1
  these routes answered 200 with garbage (and `lock` would set an edit lock on a non-existent id).
- Fix: `get_history_event()` returns `status => ERROR` when the row is missing; the history route
  and the lock route return 404 when the event (or history entry) does not exist.
- After: `/events/999/lock`, `/history/999/999`, `/history/1/999` → 404; `/events/1/lock` → 200
  `{"status":0,"modifier":"morgue_user"}`; `/history/1/1` → 200.
- Category: app-code. Time: <1 min.

#### 5.15 Web-path deprecation audit (tool) — 06:09Z
- Problem: with the accepted runtime config, Slim's handler swallows *all* deprecations on the
  web path, app ones included (5.1), and at plain E_ALL Slim's own deprecations kill every
  request. So nothing so far had looked for app deprecations in request handlers.
- Added `docs/php84-spike/harness/audit-web.sh`: runs `run.sh` with `KEEP=1`, temporarily patches
  the local `vendor/slim/slim/Slim/Slim.php::handleErrors()` to `error_log()` deprecations and
  continue, serves at full `E_ALL`, exercises 41 requests (every GET route with real and missing
  ids, and every write route: POST/PUT/DELETE for events, history, tags, forum links, images,
  slack channels, tickets, timezone, delete + undelete), restores the vendor file on exit (trap),
  and fails on any PHP log line outside `vendor/` or any 5xx.
- First audit result: 0 × 5xx; vendor entries = the accepted list (+ item 6 above, newly seen);
  **7 app findings**, all PHP 8.1 "Passing null to parameter #1 ($string|$datetime) of type string
  is deprecated": `phplib/Postmortem.php:47,559` (`new DateTime(null)`), `htdocs/index.php:134`,
  `features/anniversary/routes.php:11,38,90` (`trim(null)`), `features/search/routes.php:5`
  (`urldecode(null)`) → 5.16.
- Verified afterwards: `git -C vendor/slim/slim status --short` is empty (vendor restored).
- Category: tooling. Time: 2 min.

#### 5.16 Null passed to non-nullable string parameters (8.1, predicted P14) — 06:09Z
- Errors (audit 5.15): `DateTime::__construct(): Passing null to parameter #1 ($datetime) of type
  string is deprecated` (phplib/Postmortem.php:47 on create, :559 on history), `trim(): Passing null
  to parameter #1 ($string)` (htdocs/index.php:134 on `GET /` without `?tags`,
  features/anniversary/routes.php:11,38,90 without `?date`), `urldecode(): Passing null …`
  (features/search/routes.php:5 without `?q`).
- Root cause: Slim's `request->get('x')` returns null for an absent parameter; PHP 8.1 deprecates
  null for internal scalar parameters (7.x coerced it to "" silently). `new DateTime(null)` relied
  on the same coercion to mean "now".
- Fix: `new DateTime('now', …)`; `trim($app->request->get('x') ?? '')`; `urldecode($q ?? "")`.
  Same values as the old coercion.
- After: `audit-web.sh` → app findings 0, 5xx responses 0 (41 requests); vendor entries are only
  the accepted Slim list.
- Category: app-code. Time: <1 min.

#### 5.17 Clean-room re-run: GREEN — 06:17Z
- Command: `rm -rf vendor config/development.json && docs/php84-spike/harness/run.sh` (image
  rebuilt from the Dockerfile, vendor reinstalled from the committed lock).
- Result: `HARNESS GREEN` — runtime policy PHP 8.4.27 ≥ 8.4.27, pdo_mysql, `composer install`
  (used the `--prefer-source` fallback automatically), 7 schemas, 7 smoke checks, `OK (11 tests,
  16 assertions)` at E_ALL. Web audit (`audit-web.sh`) separately: 41 requests, 0 × 5xx, 0 app
  findings.
- Category: tooling. Time: 7 min (unattended; mostly the source install).

### 6. Re-verify (runtime + security) — 06:18Z → 06:25Z
- `php -v` in the image: `PHP 8.4.27 (cli) (built: Oct 21 2026 15:53:07) (NTS)`. Runtime policy
  script `docs/php84-spike/harness/policy-php-version.sh`: PASS for `morgue-php:local`, FAIL for
  `php:7.1-cli` (7.1.33). The harness runs the same check first.
- Syft 1.55.0 / Grype 0.121.0 (DB 2026-10-26) / Trivy 0.76.1 on before/after images and lockfiles;
  full table in `docs/php84-spike/SECURITY-VERIFICATION.md`. Headline: after = 0 PHP2Shell and 0 Twig
  findings (Twig before: Trivy 4 critical / 5 high / 6 medium / 1 unknown; Grype 1/3/5/5).
- Failure 6a: `grype db status` → "database does not exist" right after a successful
  `db update`. Root cause: the image's cache dir is `/.cache/grype`, not `/root/.cache/grype`, so
  the volume was mounted in the wrong place. Fix: mount at `/.cache/grype`. Category: tooling.
- Finding 6b: Trivy reports no PHP at all in either image (source-built PHP has no dpkg record),
  so its PHP2Shell verdict is the same "clean" for 7.1.33 and 8.4.27.
- Finding 6c: Grype + Syft's binary classifier DO see `php-cli 7.1.33`, but match only
  CVE-2026-109619: the NVD CPE range for CVE-2026-109618 starts at 7.3.0, so EOL 7.1 is silently
  "not affected". Exposure detection for EOL runtimes must be a version policy, not a CVE match.
- Category: security-verification. Time: 7 min.

## Summary — 2026-10-27T06:23Z

**Outcome: DONE.** `spike/php84` runs morgue on PHP 8.4.27. `harness/run.sh` is green from a
clean checkout (phpunit 11/11 at E_ALL; DB smoke creates and reads a postmortem; no PHP warnings
or fatals), `audit-web.sh` is clean over 41 requests at E_ALL, and the security re-verification
shows no PHP2Shell and no Twig findings.

**Time:** session 2 ran 05:33Z → 06:23Z = **~50 min wall-clock** (plus 5 min of session 1),
of which ~12 min was waiting on git-source Composer installs. By category: tooling/harness
~15 min, dependency ~16 min, framework-vendor ~2 min, app-code ~8 min, tests ~3 min,
security ~7 min.

**Step list:** 1 harness → 2 static scan → 3 Dockerfile 8.4.27 → 4 composer.json + lock (Twig
removed, sabre/dav 4.7.1, phpunit 11.5.57, merge-plugin 2.1.0, Slim polyfill) → 5.1 Slim
deprecations accepted by ini → 5.2 Slack null → 5.3–5.6 PHPUnit 11 → 5.7–5.8 dynamic properties →
5.9–5.11 8.x deprecations → 5.12 mcrypt constants → 5.13–5.14 missing-id 500s → 5.15 web audit
tool → 5.16 null-to-string → 5.17 clean re-run → 6 security re-verify.

**Top surprises**
1. Slim 2's error handler turns E_DEPRECATED into exceptions, so vendor deprecations are fatal,
   and the sanctioned suppression (`~E_DEPRECATED`) also hides app deprecations. A patched-handler
   audit found 7 that tests and smoke never showed (5.1, 5.15, 5.16).
2. Scanners: Trivy is blind to source-built PHP (identical "clean" for 7.1.33 and 8.4.27). Grype
   via Syft's binary classifier sees it, but NVD's range for CVE-2026-109618 starts at 7.3.0, so
   EOL 7.1 matches only CVE-2026-109619. Only a runtime version policy is reliable (6).
3. Composer 2.10 refuses to resolve versions with security advisories (Twig 1.x, PHPUnit 6) before
   PHP compatibility is even considered (3).
4. Egress/toolchain: GitHub API zipballs refused while git clones are allowed → `--prefer-source`;
   merge plugin needs a second resolve and ignores `--prefer-source` in its nested update; Docker
   Hub 429s (3, 4).
5. PHP 8 changed the default `error_reporting` to E_ALL and promoted missing-key /
   offset-on-false / property-on-null to warnings. Unknown event ids went from 404 to 500, and
   an offline Slack call 500'd every event page. Both were invisible to static tools (5.2, 5.13, 5.14).

**Left unresolved / follow-ups**
- slim/slim 2.6.3 is still the framework (abandoned, no PHP 8 release). 25 vendor deprecations
  are suppressed by `docker/php/morgue.ini`, and the polyfill is a bridge. Replace Slim 2
  (Slim 4 or similar) and then drop the ini exclusion and `phplib/compat/`.
- Cookie "encryption" is a no-op (it already was on 7.1: no ext/mcrypt) and the cookie secret
  `PMS_R_US` is hard-coded in `htdocs/index.php`. Session cookies rely on Slim's HMAC only. This is a
  security follow-up, not fixed here (behaviour kept identical).
- Not exercised: `POST /upload/:id` (WebDAV through sabre/dav 4.7.1; only `Sabre\DAV\Client`
  construction verified), JIRA/Slack against real APIs, the irc feature (disabled in example
  config), calendar JS, anniversary mail cron. CurlClient tests (httpbin.org) are still excluded,
  so they were not run on 8.4.
- Only the README dev server (`php -S`) was tested. Apache/FPM production config (php.ini parity,
  `error_reporting`) must be set to match `docker/php/morgue.ini` at deploy time.
- Base image OS findings (Debian 13: Trivy 2 critical / 118 high, none PHP) are a separate
  base-image patching item.

## Session 3 — measuring Rector / PHPStan against the hand-made fixes (2026-10-27, from 06:30Z)

Goal: measure which of the step-5 findings two static tools (named by
netresearch/php-modernization-skill) would have caught on the pre-fix tree `2314b75`, and fold
the result into the runbook. Tools ran in `morgue-php:local` (PHP 8.4.27) with `--network none`,
against a read-only export of `2314b75` plus the identical vendor/ (composer.json/lock unchanged).

#### 5.18 Undefined `$img` in the single-forum-link route (found by PHPStan level 0) — 06:47Z
- Found by: PHPStan 2.3.2 level 0 on the pre-fix tree, `features/links/routes.php:38 [variable.undefined]
  Undefined variable: $img`. My route crawl (5.13) and web audit (5.15) never requested
  `GET /events/:id/forum_links/:forum_link`, so neither saw it.
- Error (reproduced on the current branch): `GET /events/1/forum_links/1` → 500 "Slim Application
  Error … Message: Undefined variable $img File: /app/features/links/routes.php Line: 38".
- Root cause: copy-paste bug from the images route (`get_forum_link($img)` instead of the route
  parameter `$forum_link`). On 7.1 the undefined variable was an E_NOTICE, which the default
  error_reporting filtered out, so the call ran with null. On 8.x it is an E_WARNING, and Slim's handler
  turns it into an exception.
- Fix: `Links::get_forum_link($forum_link)`. After: `GET /events/1/forum_links/1` → 404, as on 7.1.
- Not fixed (pre-existing, not PHP-version related): it still returns 404 for an existing link,
  because `Persistence::get_association_by_id()` (phplib/Persistence.php:416) builds
  `SELECT … FROM <table>` with no `WHERE id = :id` but binds `:id`, so PDO throws and the function
  returns ERROR. That was the same on 7.1; it's listed as a follow-up.
- Category: app-code. Time: 4 min.

#### 5.19 Harness gate let PHPUnit deprecations through (found while measuring) — 06:55Z
- Found by: running the current harness on the Rector-only tree (5.20). phpunit printed
  `OK, but there were issues! Tests: 11, Assertions: 16, Deprecations: 8, PHPUnit Deprecations: 1`
  and the harness reported `PASS phpunit`.
- Root cause: PHPUnit 10+ exits 0 when tests pass but deprecations were triggered, unless
  `--fail-on-deprecation` / `--fail-on-phpunit-deprecation` (or `failOnDeprecation` in phpunit.xml) is set.
  The "no deprecations" criterion of step 5 was being checked by eye, not by the gate.
- Fix: `harness/run.sh` passes `--fail-on-deprecation --fail-on-phpunit-deprecation
  --display-deprecations --display-phpunit-deprecations`.
- Verification: Rector-only tree → `FAIL phpunit`; this branch → `PASS phpunit: OK (11 tests, 16
  assertions)`, `HARNESS GREEN`.
- Category: tests. Time: 2 min.

#### 5.20 Web audit no longer edits vendor/; crawl covers single-item GETs — 07:05Z
- Problem: `audit-web.sh` (5.15) patched `vendor/slim/slim/Slim/Slim.php` in place and restored it from
  a trap. That breaks the "never edit vendor/" guardrail in netresearch/php-modernization-skill, and it
  bit here: the measurement copy (`tool-eval/measure-tools.sh`) hardlinks vendor/, so an in-place write
  would have changed the measured tree too. It is also not crash-safe (a SIGKILL skips the trap).
- Fix: the audit now writes the patched handler to `harness/out/Slim.audit.php` and bind-mounts it
  read-only over `vendor/slim/slim/Slim/Slim.php` inside the audit container only. The script records
  the file's sha256 first and fails if it changed, and it also fails if no vendor deprecation was logged
  (patch not active). The crawl gained `GET /events/1/{forum_links,images,slack-channels,tickets}/1`
  (the gap that hid 5.18).
- Verification: `audit-web.sh` → exit 0, 45 requests, 0 app findings, 0 × 5xx, vendor deprecations
  logged (patch live), `Slim.php` sha256 `7b84c7f6b1d181ff…` before = after, `git status` clean in vendor/.
- Observation: all four single-item GETs answer 404 for existing rows. That is the pre-existing
  `Persistence::get_association_by_id()` bug from 5.18 (no `WHERE`), shared by the links, images, jira,
  slack and irc features. Same on 7.1; it's a follow-up.
- Category: tooling. Time: 5 min.
