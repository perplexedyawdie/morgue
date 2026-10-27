# Runbook: PHP runtime upgrade for a legacy application

A general procedure for moving a legacy PHP application (old framework, old test suite, no
recent maintenance) onto a supported, security-fixed PHP release. It was distilled from a
hand-done spike: etsy/morgue went from PHP 7.1 to 8.4.27 to fix PHP2Shell (CVE-2026-109618 /
CVE-2026-109619). See `JOURNAL.md` for the step-by-step evidence.

**How to use it.** Each `WI-n` section is a work-item template. A planning agent turns each into
one issue for one specialist agent: fill in the `<placeholders>`, keep the acceptance criteria
as the issue's definition of done, and wire the "Depends on" lines into issue links. Every
acceptance criterion has a command, so a reviewer agent can check it mechanically.

**Placeholders used throughout**

| Placeholder | Meaning | morgue value |
|---|---|---|
| `<TARGET>` | exact PHP patch release to run | `8.4.27` |
| `<FIXED_MIN>` | first release on each supported branch with the fix | 8.2.35 / 8.3.36 / 8.4.27 / 8.5.12 |
| `<IMAGE>` | runtime image tag built from the repo | `morgue-php:local` |
| `<HARNESS>` | the one-command acceptance harness | `docs/php84-spike/harness/run.sh` |
| `<SRC_DIRS>` | first-party PHP directories | `htdocs phplib features views tests` |

**Dependency graph** (→ = "must finish before")

```
WI-1 harness ─┬─→ WI-3 static scan ─┐
              │                     ├─→ WI-4 runtime bump → WI-5 deps+lock ─┬─→ WI-6 vendor shims → WI-7 app fixes ─┐
WI-2 exposure ┘ (parallel with 1/3) │                                        └─→ WI-8 test migration ─────────────┤
                                    └──────────────────────────────────────────────────────────────────────────────┴─→ WI-9 security re-verify → WI-10 release
```
WI-2 and WI-3 can run in parallel with WI-1. WI-7 and WI-8 run in parallel once WI-5 is done
(they touch different files) but share the harness, so they must merge in sequence.

---

## WI-1 Baseline and acceptance harness

- **Goal:** one command that proves "the app works" on any runtime image, so every later work
  item has an objective definition of green.
- **Specialist role:** harness / QA.
- **Inputs:** repo; README run instructions; DB schemas; the list of critical user journeys;
  known baseline facts (versions, test counts) if a baseline can't be reproduced.
- **Tasks:**
  1. Containerise everything the harness needs (DB + app runtime), so the PHP under test is
     only the one in `<IMAGE>`. Never use the host's PHP.
  2. Load schemas in **dependency order**, not alphabetical (views after their tables). Skip
     upgrade migrations on a fresh DB.
  3. Generate the app config from the shipped example and point it at the harness DB.
  4. Start the app the way developers do (e.g. `php -S` per the README) with
     `display_errors=On`, `log_errors=On`, `error_log=<file>`.
  5. Smoke the critical journeys: health endpoint, home page, **one write + read-back that hits
     the DB** (create a record, follow the redirect, assert the content, assert the row exists).
  6. Fail on: non-2xx/3xx, PHP error text in any body, the framework's own error page, and any
     `PHP Fatal|Parse|Warning|Notice|Deprecated` line in the error log.
  7. Run the unit tests and exclude only tests that are flaky for external reasons (network),
     by name, with a recorded reason.
  8. Make it one command with knobs (image, ports, error level, skip build/install); write
     outputs to a gitignored dir.
  9. Record the baseline result (on the old runtime if it can still be built; otherwise from
     earlier evidence) as the comparison point: test count, passing journeys.
- **Acceptance criteria:**
  - `<HARNESS>` exits 0 on the baseline runtime, or the baseline is documented as not
    reproducible with the reason and the last known numbers. Verify: `echo $?` after the run.
  - The harness fails when a deliberate warning is injected (e.g. temporarily add
    `trigger_error('x', E_USER_WARNING);` to a route). Verify: run → non-zero, log line shown.
  - The DB journey asserts persistence. Verify: harness output has a "row persisted" PASS.
- **Depends on:** nothing.
- **Risks / rollback:** the harness only covers what it exercises (see WI-7 route crawl); the
  framework's error handler may hide errors (see WI-6). Rollback: none needed (additive).
- **Example (morgue):** JOURNAL §1 (harness design), §5.17 (clean-room green run). MariaDB
  10.4 with `postmortems.sql` → other schemas → `anniversary.sql`; `POST /events` needs every
  NOT NULL field; CurlClient tests excluded (they call httpbin.org).

## WI-2 Detect and confirm exposure

- **Goal:** prove which deployed artifacts run a vulnerable PHP, and make sure the detection
  method can't produce a false "clean".
- **Specialist role:** security-verification.
- **Inputs:** deployed image(s); CVE IDs; the vendor's list of fixed releases (`<FIXED_MIN>`);
  PHP's supported-versions table (which branches are EOL).
- **Tasks:**
  1. Ask the interpreter: `docker run --rm <image> php -r 'echo PHP_VERSION;'`. This is the
     ground truth.
  2. Generate an SBOM with a tool that has a **binary classifier** (Syft finds `php-cli` in
     `/usr/local/bin/php`). OS-package-based scanners (Trivy, GitLab Container Scanning, GitLab
     SBOM) do not see a PHP compiled from source, which is how the official `php:*` images are
     built.
  3. Match the SBOM with Grype, and check the CVE's NVD CPE ranges
     (`grype db search --vuln <CVE> -o json`). EOL branches are often outside the published
     range, so they show as "not affected" although they will never get a fix.
  4. Write a runtime policy: `PHP_VERSION >= <FIXED_MIN for its branch>` AND the branch is
     supported. Anything on an EOL branch fails.
- **Acceptance criteria:**
  - Every deployed image is listed with its interpreter-reported PHP version. Verify: the
    policy script output per image.
  - The policy script fails on the current production image. Verify:
    `policy-php-version.sh <prod-image> <FIXED_MIN>` → exit 1.
  - The report states which scanners can and cannot see the runtime. Verify: Syft table has a
    `php-cli … binary` row; Trivy JSON has no PHP package.
- **Depends on:** nothing (can run first, to justify the work).
- **Risks / rollback:** relying on a scanner's CVE match gives false negatives on EOL runtimes
  and source-built PHP. Rollback: n/a (read-only).
- **Example (morgue):** SECURITY-VERIFICATION.md; JOURNAL §6. Trivy: 0 PHP findings on both
  7.1.33 and 8.4.27. Grype on 7.1.33 matched only CVE-2026-109619, because NVD's range for
  CVE-2026-109618 starts at 7.3.0.

## WI-3 Static compatibility scan (before changing code)

- **Goal:** a predicted-breakage list, so the fix loop is targeted and its results can be
  checked against a forecast.
- **Specialist role:** compat-scan.
- **Inputs:** repo; `<TARGET>` image (just the official base is enough); the resolved vendor
  tree of the *old* lock if available.
- **Tasks:**
  1. `php -l` with `<TARGET>` on every first-party file, with `error_reporting=E_ALL` (it reports
     compile-time deprecations too).
  2. `phpcs --standard=PHPCompatibility --runtime-set testVersion <TARGET major.minor>` over
     `<SRC_DIRS>`. Use **PHPCompatibility 10.x** (alpha): 9.3.5, the last stable, has no sniffs
     for PHP 8.1–8.4.
  3. Run the same scan over **abandoned vendor packages** (fetch them into a scratch dir). The
     framework is usually where the hard blockers are.
  4. Grep for removed functions and extensions (`each`, `create_function`, `mcrypt_*`,
     `get_magic_quotes_*`, `mysql_*`, `utf8_encode`, `strftime`, `FILTER_SANITIZE_STRING`, …) and
     for constants of removed extensions.
  5. Run a dynamic-property sweep (tokenizer script: `$this->x =` writes vs declared properties)
     over first-party classes. PHPCompatibility does not catch 8.2 dynamic properties.
  6. Write `static-scan.txt`: raw output plus a numbered predicted-breakage list split into
     fatal / deprecation / vendor / "not statically detectable" (dependency resolution, test
     framework API, null-to-string, undefined keys).
- **Acceptance criteria:**
  - `static-scan.txt` is committed with tool versions and exact commands. Verify: file exists
    and names the PHPCompatibility version.
  - Vendor framework is scanned. Verify: the file has a vendor section.
- **Depends on:** nothing (WI-1 helps to know which code paths matter).
- **Risks / rollback:** static tools miss runtime-only issues and anything an error handler
  changes. Treat the list as a forecast, not a scope. Rollback: n/a.
- **Example (morgue):** static-scan.txt sections A–E (before) and F (after + predicted vs
  actual); JOURNAL §2. The scan found reversed `implode()` arguments that an earlier grep had
  missed, and mcrypt constants in Slim's default settings.

## WI-4 Runtime bump

- **Goal:** a reproducible runtime image on exactly `<TARGET>` with the extensions the app needs
  and a current Composer.
- **Specialist role:** runtime-bump.
- **Inputs:** `<TARGET>`; extension list (`php -m` diff between old and new); old build shims.
- **Tasks:**
  1. `FROM php:<TARGET>-<variant>`. Pin the **patch** version and never float to the minor tag,
     since the patch is the security fix.
  2. Install the required extensions (`docker-php-ext-install pdo_mysql …`) plus `git` and
     `unzip` (Composer needs unzip or ext-zip for dists, and git for source installs).
  3. Pin Composer by version (`COPY --from=composer:<x.y.z>`), not `composer:latest`.
  4. Bake a runtime ini (`conf.d/zz-app.ini`). PHP 8's built-in default `error_reporting` is
     `E_ALL`, where 7.x defaulted to `E_ALL & ~E_NOTICE & ~E_STRICT & ~E_DEPRECATED`. The official
     images ship no php.ini, so pick the level explicitly and keep it the same in dev, test and
     prod.
  5. Remove the old runtime's build shims (archived apt sources, Composer 1/2.2 pins); record
     which ones became unnecessary.
  6. If builds run behind a TLS-intercepting proxy, support an optional CA dir and the
     `HTTPS_PROXY` build arg without hard-coding either.
- **Acceptance criteria:**
  - `docker run --rm <IMAGE> php -v` shows exactly `<TARGET>`. Verify: the first line.
  - Required extensions are loaded. Verify: `php -m | grep -x pdo_mysql` (etc.).
  - Runtime policy passes. Verify: `policy-php-version.sh <IMAGE> <FIXED_MIN>`.
- **Depends on:** WI-1 (to run the harness against the new image).
- **Risks / rollback:** Docker Hub anonymous pull limits (429) in shared CI; pre-pull or use a
  mirror you are allowed to use. Rollback: keep the old image tag deployable until WI-10.
- **Example (morgue):** JOURNAL §3 (Dockerfile, 429s, https apt sources behind the proxy),
  §5.1 (`docker/php/morgue.ini`), §5.13 (default error_reporting change).

## WI-5 Dependency resolution and lockfile

- **Goal:** a committed lockfile that resolves for `<TARGET>`, has no known advisories, and
  installs reproducibly.
- **Specialist role:** dependency.
- **Inputs:** composer.json (+ any merged sub-manifests); WI-3's list; usage grep for every
  direct dependency.
- **Tasks:**
  1. Set `require.php` to the supported range (`>=<TARGET> <next minor>`) and
     `config.platform.php` to `<TARGET>`, so resolution doesn't depend on the machine running it.
  2. For each direct dependency, grep for real usage. **Remove unused ones** before trying to
     upgrade them; it is the cheapest fix there is.
  3. Move each remaining dependency to the lowest major that supports `<TARGET>`; check the API
     the app actually calls against the new major.
  4. Replace `dev-master` constraints with released ranges; add `config.allow-plugins` for
     every Composer plugin (Composer 2.2+ refuses to run unlisted plugins).
  5. Resolve with a current Composer. Recent Composer 2 releases **block versions that have
     security advisories during resolution** (`policy.advisories.block`); read those errors as
     "this version is not allowed" and don't switch blocking off.
  6. If a merge plugin pulls in sub-manifests, run `composer update` **twice**: on the first
     resolve the plugin isn't installed yet, so the sub-manifest requirements are missing from
     the lock.
  7. If dist downloads are refused (restricted egress, API rate limits), install with
     `--prefer-source` and cache `~/.composer/cache` between runs.
  8. Remove `composer.lock` from `.gitignore` and commit the lock.
  9. Run `composer audit` and `composer audit --abandoned=report`. Separately review
     abandoned *major lines* (a live package name can hide a dead 2.x).
- **Acceptance criteria:**
  - Lock committed and fresh. Verify: `git ls-files composer.lock`; `composer validate` reports
    no stale lock.
  - Clean install from the lock. Verify: `rm -rf vendor && composer install` exits 0.
  - No advisories. Verify: `composer audit` → "No security vulnerability advisories found".
  - Every package in the old manifest is upgraded, removed with a usage grep as evidence, or
    pinned with a reason. Verify: dependency table in the work item.
- **Depends on:** WI-4.
- **Risks / rollback:** major bumps change APIs on code paths the harness doesn't cover; list
  them for WI-7. Rollback: revert composer.json + composer.lock together.
- **Example (morgue):** JOURNAL §3 (advisory blocking on twig 1.x / phpunit 6), §4 (Twig
  removed as unused; sabre/dav 2.1 → 4.7; merge-plugin dev-master → ^2.1 with allow-plugins;
  two-pass resolve; `--prefer-source` fallback).

## WI-6 Framework / vendor shims

- **Goal:** keep an abandoned framework running on `<TARGET>` with the smallest, most explicit
  intervention, and know exactly what is being tolerated.
- **Specialist role:** framework-shim.
- **Inputs:** WI-3 vendor section; framework source; how the framework handles PHP errors.
- **Tasks:**
  1. Read the framework's **error handler** before anything else. Many legacy frameworks
     (Slim 2, old Zend/CodeIgniter) turn every error level enabled in `error_reporting()` into an
     exception. That makes vendor deprecations fatal, and it also means the levels you exclude are
     swallowed for app code too.
  2. For removed functions or constants that the vendor calls unqualified, try in order and stop
     at the first that works:
     a. **App-level polyfill** loaded before the framework (Composer `autoload.files`), with every
        symbol guarded by `function_exists`/`defined`. Works when calls are unqualified, so
        namespace fallback reaches the global function.
     b. **composer-patches** patch to the vendor package (needed for syntax/class removals,
        fully-qualified calls, or to *fix* deprecations rather than suppress them).
     c. A maintained **fork** of the framework line.
     Record which one worked and why the earlier ones failed or weren't needed.
  3. For vendor **deprecations**: either patch (2b) or accept them through runtime config
     (`error_reporting = E_ALL & ~E_DEPRECATED`). If you accept them, enumerate every one (load
     every vendor class at E_ALL and collect the messages, plus the runtime ones from WI-7's
     audit), and put the list in the ini comment and the work item.
  4. Open a follow-up issue to replace the framework. The shim is a bridge, not an endpoint.
- **Acceptance criteria:**
  - App boots and serves requests on `<TARGET>`. Verify: `<HARNESS>` smoke section PASS.
  - Accepted vendor deprecations are listed exhaustively. Verify: the class-loading enumeration
    script output matches the documented list.
  - Shims are guarded and in one file. Verify: `php -d error_reporting=E_ALL -l <shim file>`.
- **Depends on:** WI-5.
- **Risks / rollback:** suppressing E_DEPRECATED globally hides app deprecations on the web
  path. Mitigate with WI-7's web audit and by running tests at E_ALL. A future PHP minor may turn
  a tolerated deprecation into an error, so re-check on every minor bump. Rollback: remove the
  shim file + ini line.
- **Example (morgue):** JOURNAL §4 (polyfill `phplib/compat/slim2_php8.php`: `get_magic_quotes_gpc`
  and the mcrypt constants that `Slim::getDefaultSettings()` reads on every request), §5.1 (Slim's
  `handleErrors()` made `#[\ReturnTypeWillChange]` deprecations fatal; 25 accepted deprecations
  listed).

## WI-7 App code fixes (driven by tests and runtime errors)

- **Goal:** zero PHP warnings/fatals and zero first-party deprecations on every route, at
  `E_ALL`.
- **Specialist role:** compat-fix.
- **Inputs:** WI-3 predicted list; harness; route list (grep the router definitions).
- **Tasks:**
  1. Loop: run the harness → take the first failure → fix it → rerun. **One commit per fix**,
     each with the exact error, root cause and category in the message or journal.
  2. Fix the predicted items (WI-3) even when no test reaches them.
  3. **Crawl every route**, not just the smoke journeys: each GET with an existing id and a
     missing id, and each write route (POST/PUT/DELETE) with plausible data. Fail on any 5xx.
  4. **Web-path deprecation audit:** if the framework's handler swallows deprecations, patch the
     *local* vendor handler for the duration of the audit only (log and continue), serve at
     `E_ALL`, crawl, restore the file, and report entries outside `vendor/`.
  5. Typical PHP 7 → 8.x runtime classes to expect (in rough order of frequency):
     - null passed to non-nullable internal params (8.1): `trim(null)`, `new DateTime(null)` →
       `?? ''`, `'now'`;
     - undefined array key / array offset on `false` (warning since 8.0): `fetch()` returning
       `false` treated as an array → return the documented "not found" shape, respond 404;
     - property read on null (warning since 8.0): failed `json_decode` of an external API →
       `empty($x->ok)`;
     - dynamic properties (8.2) → declare them (with the visibility the callers need);
     - removed argument orders / signatures (8.0): `implode($array, $glue)` → TypeError;
     - implicitly nullable params (8.4), optional-before-required params (8.0),
       `E_USER_ERROR` (8.4), `${var}` interpolation (8.2).
  6. Code that calls external services on page render (chat or ticket APIs) must tolerate
     having no network. CI and sandboxes often have none.
- **Acceptance criteria:**
  - Harness green. Verify: `<HARNESS>` → `HARNESS GREEN`.
  - Route crawl has no 5xx. Verify: audit request log `grep -c '^5'` → 0.
  - Web audit has 0 first-party findings. Verify: audit-findings file is empty.
  - Static rescan is clean. Verify: `php -d error_reporting=E_ALL -l` and PHPCompatibility over
    `<SRC_DIRS>` → 0 findings.
- **Depends on:** WI-6 (the app must boot); WI-8 for test-driven fixes.
- **Risks / rollback:** "fixing" a warning by suppressing it (`@`, broad `isset`) can hide
  behaviour changes. Prefer restoring the old *semantics* (e.g. old `null`→`""` coercion via
  `?? ''`). Rollback: each fix is its own commit; revert individually.
- **Example (morgue):** JOURNAL §5.2 (Slack API null), §5.5 (implode), §5.7–5.8 (dynamic
  props found by the sweep), §5.9–5.11, §5.13–5.14 (missing-id 500s found only by crawling),
  §5.15–5.16 (web audit found 7 null-to-string deprecations hidden by the framework handler).

## WI-8 Test-suite migration

- **Goal:** the existing tests run unchanged in meaning on the new test framework major, at
  `E_ALL`, with no framework deprecations (ready for the next major).
- **Specialist role:** test-migration.
- **Inputs:** test dir; old/new PHPUnit majors; baseline test count.
- **Tasks (PHPUnit 6 → 11 checklist):**
  1. `setUp()/tearDown()/setUpBeforeClass()` → `protected function setUp(): void` etc. A
     signature mismatch fatals while loading, even for tests a `--filter` excludes.
  2. File name must match class name (PHPUnit 10 dropped the fallback): `Foo_Test.php` holding
     `FooTest` → rename the file.
  3. Data providers must be `public static`; `@dataProvider` → `#[DataProvider('…')]` (doc-comment
     metadata is deprecated in 11, removed in 12).
  4. `->will($this->returnValue(x))` → `->willReturn(x)`; `createMock($class, $methods)` → one
     argument; `getMockBuilder()->setMethods()` → `->onlyMethods()`.
  5. Declare properties used in `setUp()` (8.2 dynamic properties apply to test classes too).
  6. Run with `--display-deprecations --display-phpunit-deprecations` until both are empty.
- **Acceptance criteria:**
  - Same number of tests as the baseline, all passing. Verify: `phpunit` output `OK (<N> tests`
    with `<N>` = baseline count.
  - No deprecations. Verify: `--display-deprecations --display-phpunit-deprecations` shows none.
- **Depends on:** WI-5 (new PHPUnit in the lock).
- **Risks / rollback:** a provider that errors silently drops its cases. Compare the test count,
  not just "green". Rollback: revert test commits.
- **Example (morgue):** JOURNAL §5.3–5.6. The count went 7 → 11 once the data provider was
  static; 11 matches the 7.1 baseline.

## WI-9 Security re-verification

- **Goal:** evidence that the exposure from WI-2 is gone and nothing new was introduced.
- **Specialist role:** security-verification.
- **Inputs:** before/after images; before/after lockfiles; CVE IDs; WI-2 method.
- **Tasks:**
  1. Runtime policy on the new image (interpreter version ≥ `<FIXED_MIN>`, supported branch).
  2. Syft SBOM of the image (must show the runtime binary) → Grype; Trivy on the image and the
     lockfile. Record before/after counts per severity, and specifically the target CVEs and any
     removed dependency's CVEs.
  3. `composer audit` on the committed lock.
  4. State which tools are blind to which component (e.g. Trivy for source-built PHP) so nobody
     reads a blind "0" as a pass.
- **Acceptance criteria:**
  - Policy passes on new, fails on old. Verify: `policy-php-version.sh <new>` exit 0,
    `policy-php-version.sh <old>` exit 1.
  - Target CVEs absent from the Grype results for the new image, and the runtime is present in
    the SBOM. Verify: `jq` over grype JSON for the CVE IDs → none; Syft table has the
    `php-cli <TARGET>` row.
  - Lockfile findings = 0 (or each one accepted with a reason). Verify: `grype dir:.`,
    `trivy fs .`, `composer audit`.
- **Depends on:** WI-7, WI-8.
- **Risks / rollback:** the scanner DB may predate the CVE. Check `grype db status` "Built"
  against the disclosure date. Rollback: n/a.
- **Example (morgue):** SECURITY-VERIFICATION.md; JOURNAL §6 (Twig: Trivy 4C/5H → 0; PHP2Shell
  matched on 7.1.33 only through CVE-2026-109619; Trivy blind to PHP in both images).

## WI-10 Release / deploy readiness

- **Goal:** ship the new runtime safely and make the change reversible.
- **Specialist role:** release.
- **Inputs:** WI-9 report; deployment manifests; production php.ini / FPM config; monitoring.
- **Tasks:**
  1. Make production ini match the harness (same `error_reporting`, `display_errors=Off`,
     `log_errors=On`). The PHP 8 default-level change (WI-4) is a common prod-only surprise.
  2. Switch the deployed image to the pinned `<TARGET>` tag/digest; keep the previous image
     deployable for rollback, and don't roll back the DB (no schema change is expected from a
     runtime bump; verify that).
  3. Canary or staging soak: watch the PHP error log for any new `PHP Warning|Fatal`, and for
     5xx on routes the crawl didn't cover (uploads, integrations behind credentials).
  4. Add the runtime policy check and the harness to CI so a later image change can't regress
     to a vulnerable or EOL PHP.
  5. File follow-ups: replace the abandoned framework (WI-6), remove shims and the ini
     deprecation exclusion, patch base-image OS findings, re-enable network-dependent tests in
     an environment with egress.
- **Acceptance criteria:**
  - CI runs harness + policy on every merge. Verify: pipeline config contains both jobs and a
    pipeline on the release commit is green.
  - Rollback is documented and was tested once in staging. Verify: runbook link plus staging
    deploy log.
  - Production reports `<TARGET>`. Verify: a health/version endpoint or
    `kubectl exec … php -v` / equivalent.
- **Depends on:** WI-9.
- **Risks / rollback:** integrations not covered by tests (uploads/WebDAV, chat/ticket APIs)
  may still fail with real credentials. Keep the soak until they've been exercised. Rollback:
  redeploy the previous image tag.
- **Example (morgue):** not executed in the spike. Open items are listed at the end of
  JOURNAL.md.

---

## Pitfalls (toolchain rot and traps seen in the spike)

1. **The old runtime may no longer build.** EOL Debian images need `archive.debian.org`
   sources (drop the security/updates lines, `Acquire::Check-Valid-Until=false`). Composer 1 was
   shut down by Packagist in Sept 2025, and the `composer:1.x` image tags now run a PHP that
   Composer 1 can't. Build the baseline with Composer 2.2 LTS.
2. **Plugin version gaps.** No `wikimedia/composer-merge-plugin` release supports PHP 7.1 *and*
   Composer 2. The baseline had to inline the merged requirement; on the new side, the plugin
   needs `allow-plugins` and a two-pass `composer update`.
3. **Schema load order.** `docker-entrypoint-initdb.d` loads files alphabetically, so a VIEW
   file sorting before its table breaks the init. Load in dependency order yourself.
4. **Composer blocks insecure versions during resolution** (recent Composer 2): an old manifest
   fails with "found … but these were not loaded, because they are affected by security
   advisories" before PHP compatibility is even checked. Fix the dependency; don't pass
   `--no-security-blocking` except to reproduce a baseline for comparison.
5. **The framework's error handler changes what "deprecation" means.** Slim 2 throws on every
   enabled level, so vendor deprecations become fatal, and excluding E_DEPRECATED also silences
   app deprecations on the web path. Audit with a temporarily patched handler.
6. **PHP 8 changed the built-in default `error_reporting` to E_ALL**, and the official images ship
   no php.ini. Notices that 7.x never showed (undefined index, array offset on bool) are now
   warnings at full volume.
7. **Scanners vs source-built PHP.** Trivy and GitLab Container Scanning/SBOM don't see PHP in
   `php:*` images; Syft's binary classifier does. Even then, NVD CPE ranges often skip EOL
   branches (CVE-2026-109618 starts at 7.3.0), so an EOL runtime can look "not affected". Gate on
   a version policy.
8. **Restricted egress.** Packagist dists point at the GitHub API (zipballs), which some
   sandboxes/CI networks refuse while still allowing git clones: use `--prefer-source` + a
   Composer cache. Docker Hub anonymous pulls hit 429 on shared IPs: retry/pre-pull or use an
   approved mirror. Containers behind an intercepting proxy need the proxy env and CA passed in
   explicitly (`--network host`, `SSL_CERT_FILE`, `GIT_SSL_CAINFO`, a CA dir in the image).
9. **Static tools are version-gated too.** PHPCompatibility 9.3.5 (last stable) knows nothing
   past 8.0; use 10.x alpha. Neither catches dynamic properties, so run a sweep.
10. **Tests that a filter excludes still get loaded.** A PHPUnit signature fatal in an
    "excluded" file kills the whole run.
11. **Abandoned-but-alive names.** `composer audit --abandoned` won't flag `slim/slim` 2.x
    because the package (v4) is maintained. Judge abandonment per major line.
12. **Render-time calls to external APIs** (Slack, JIRA) pass in a networked CI and fail in an
    offline one. On PHP 8 the failure path (`json_decode(false)->ok`) is a warning, which the
    framework turns into a 500.
