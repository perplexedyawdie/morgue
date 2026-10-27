# Would Rector / PHPStan have found what the hand-done fix loop found?

Measured 2026-10-27 against the morgue pre-fix tree `2314b75` (deps already moved to PHP 8.4,
Slim polyfill in place, no app-code fixes yet). Tools were named by
[netresearch/php-modernization-skill](https://github.com/netresearch/php-modernization-skill);
the skill's repo was read as data only (its scripts were not run).
Reproduce: `docs/php84-spike/tool-eval/measure-tools.sh 2314b75 <workdir>` (a full rerun from fresh
clones gave identical results).

## Method

- **Runtime:** `morgue-php:local` (PHP 8.4.27); every analysis container ran with `--network none`
  against a read-only copy of the tree plus the identical `vendor/`.
- **Tools:** PHPStan 2.3.2 + phpstan-deprecation-rules 2.0.5 (`phpVersion: 80400`, levels 0–10);
  Rector 2.8.1 in four configs:
  - A: `withPhpSets(php84: true)`
  - B: A + `withComposerBased(phpunit: true)`
  - C: B + opt-in `NullToStrictStringFuncCallArgRector` and `CompleteDynamicPropertiesRector`
  - D: **targeted**, only the 5 PHP rules that matched a defect + the PHPUnit composer sets
- **Ground truth:** the 20 defect groups fixed in JOURNAL 5.2–5.18 (G01–G20, sites listed in `score.py`).
  The vendor/framework items (5.1) are out of scope for app-level tools.
- **Scoring:**
  - PHPStan: an item counts only when a finding on its line has an identifier that describes the
    defect. Findings that are only about `mixed` are counted as **generic**: true, but indistinguishable
    from hundreds of other `mixed` findings at that level.
  - Rector: the config is *applied* to a copy, and `defect_check.py` tests whether each defect is still
    there. The checker reports all 20 open on `2314b75` and all 20 fixed on the branch head.

## Result matrix

| Item | Journal | Defect | php -l + PHPCompatibility 10 (step 2) | PHPStan: first level (precise+generic sites) | Rector B / D fixes it | How the hand process found it |
|---|---|---|---|---|---|---|
| G01 | 5.2 | property read on `json_decode()` null (Slack) | – | L9 (0+3 of 3) | – | harness smoke (500) |
| G02 | 5.3 | `setUp()` without `: void` | – | **L0** (2/2) | ✔ | phpunit fatal |
| G03 | 5.4 | test file name ≠ class name | – | – | – | phpunit "cannot be found" |
| G04 | 5.5 | `implode()` reversed args (TypeError) | ✔ | L5 (2/2) | ✔ | phpunit TypeError |
| G05 | 5.6 | non-static data provider | – | – | ✔ | phpunit |
| G06 | 5.6 | `@dataProvider` doc-comment | – | – | ✔ | phpunit deprecation |
| G07 | 5.6 | `returnValue()` deprecated | – | **L0** (1/1) | – | phpunit deprecation |
| G08 | 5.6 | `createMock()` extra arg | – | L1 (1/1) | ✔ | reading the test |
| G09 | 5.6 | dynamic props on test classes | – | **L0** (3/3) | – | phpunit deprecation |
| G10 | 5.7 | JiraClient dynamic props | – | **L0** (all) | – | phpunit deprecation |
| G11 | 5.8 | Calendar / Uploader_Webdav dynamic props | – | **L0** (all) | – | hand-written tokenizer sweep |
| G12 | 5.9 | implicitly nullable param (8.4) | ✔ | **L0** (1/1) | ✔ | php -l |
| G13 | 5.10 | optional before required param | ✔ | **L0** (1/1) | ✔ (differently, see below) | php -l |
| G14 | 5.10 | `trigger_error(E_USER_ERROR)` (8.4) | ✔ | – | – | static scan |
| G15 | 5.11 | `${var}` interpolation | ✔ | – | ✔ | php -l |
| G16 | 5.12 | removed mcrypt constants in app | ✔ | – (polyfill defines them) | – | static scan |
| G17 | 5.13 | `fetch()` false used as array → 500 | – | L10 (0+1 of 2) | – | route crawl |
| G18 | 5.14 | missing id: undefined key / false autoviv → 500 | – | L10 (0+3 of 3) | – | route crawl |
| G19 | 5.16 | null passed to string params (7 sites) | – | L5 (2 of 7) → L10 (2+5 of 7) | – | web audit with patched handler |
| G20 | 5.18 | undefined `$img` → 500 | – | **L0** (1/1) | – | **missed**; found by this measurement |

PHPStan volume vs. yield on the pre-fix tree:

| Level | 0 | 1 | 2–4 | 5 | 6–8 | 9 | 10 |
|---|---|---|---|---|---|---|---|
| Findings | 47 | 184 | 258–272 | 279 | 606–633 | 715 | 1802 |
| Ground-truth items detected | 8 | 9 | 9 | 11 | 11 | 12 | 14 |

Rector, files changed / items fixed:

| Config | Files changed | Items fixed |
|---|---|---|
| A (php84 sets) | 39 | 5 (G04, G08, G12, G13, G15) |
| B (+PHPUnit sets) | 40 | **8** |
| C (+opt-in rules) | 40 | 8 (the opt-in rules did nothing, see below) |
| D (targeted) | **6** (+10/−12 lines) | **8** |

## Findings

1. **PHPStan level 0 is the best value.** With 47 findings (26 on ground-truth lines, the rest
   mostly other reads of the same undeclared properties) it finds 8 items, every dynamic property
   included (which I found with a hand-written sweep), and the one real defect the hand process
   **missed**: G20, `GET /events/:id/forum_links/:id` → 500 on PHP 8 (fixed in JOURNAL 5.18).
   - It has 4 false positives: 3 × `include.fileNotFound` for `include_path`-relative includes,
     and 1 × `staticMethod.void` (runtime check: `/report` is fine).
   - On the fixed branch, level 0 reports only those 4, so it can be a CI gate today with a
     4-entry baseline.
2. **Higher PHPStan levels don't pay off on legacy code.** Level 5 adds the `implode()` TypeError and 2
   of 7 null-to-string sites for +232 findings. Level 10 reaches the runtime-only classes (G01, G17, G18,
   G19), but only as generic "…on mixed" findings among 1,802. At level 5 the fixed branch still has
   213 findings, most of them `variable.undefined` in PHP view templates that use variables from the
   including scope. Raise the level only with a baseline (the skill's "shrink, never delete").
3. **Rector fixes the mechanical items, and the targeted config is the one to use.** B and D both
   fix 8 items (G02, G04, G05, G06, G08, G12, G13, G15). B touches 40 files, mostly cosmetic
   (`LongArrayToShortArrayRector` in 30 files, `ExplicitPublicClassMethodRector` 15, plus constructor
   promotion and `readonly` added to `Slack::$curlClient`). D touches 6 files. Both trees lint clean at
   E_ALL, and the full-set tree passes the 11 unit tests after the manual G03 rename (9 deprecations remain: dynamic properties and `returnValue()`).
4. **Rector needs review where it picks a different fix.** `OptionalParametersAfterRequiredRector`
   silenced G13 by making `$table_name` optional (`= null`) instead of removing the dead default on
   `$where`. That passes, but it weakens the signature. The skill's advice holds: review what Rector
   *adds*.
5. **The rules the skill points at for runtime classes did nothing here.**
   - `NullToStrictStringFuncCallArgRector` changed nothing: Slim 2's `request->get()` has no
     return type, so Rector can't prove an argument nullable, and `new DateTime(null)` isn't a
     function call.
   - `CompleteDynamicPropertiesRector` is deprecated in Rector 2.8 and is a no-op ("can create invalid
     properties on classes with partial type information").
   - So on an untyped legacy framework, Rector fixes none of the null-to-string or dynamic-property
     items. PHPStan level 0 *finds* the dynamic properties; a human or agent declares them.
6. **What only runtime testing finds:** G01 (render-time external API failing offline), G03
   (PHPUnit discovery), G17/G18 (missing-id paths), most of G19 (null from untyped framework getters),
   and the framework error-handler behaviour (5.1). The harness, the route crawl and the
   patched-handler audit stay necessary.
7. **Static-first coverage:** PHPCompatibility + PHPStan level ≤ 5 + Rector D together identify
   16 of 20 items before anything runs (G19 only partly) and fix 8 mechanically. Rector's 8 and
   PHPCompatibility/lint's 6 overlap in 4 (G04, G12, G13, G15).
8. **The measurement found two gaps in the spike's own tooling:**
   - The harness counted phpunit with 9 deprecations as PASS: PHPUnit exits 0 on deprecations unless
     `--fail-on-deprecation` is given. Fixed in JOURNAL 5.19.
   - The web audit edited `vendor/` in place, which would also have changed this measurement's
     hardlinked copy. It now bind-mounts a patched copy (JOURNAL 5.20).

## Raw outputs

The full JSON outputs (Rector diffs, PHPStan levels 0–10) are regenerated by `measure-tools.sh` into
its workdir and are not committed. `score.py` and `defect_check.py` are the scoring code.
