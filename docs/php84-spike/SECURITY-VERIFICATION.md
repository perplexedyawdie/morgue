# Security re-verification: PHP 7.1 baseline vs PHP 8.4.27 upgrade

Date 2026-10-27, ~06:20Z. All tools run as containers on the spike host.

| Tool | Version | DB |
|---|---|---|
| Syft | 1.55.0 | n/a |
| Grype | 0.121.0 | schema v6.1.10, built 2026-10-26T06:38Z (contains CVE-2026-109618/109619) |
| Trivy | 0.76.1 | `mirror.gcr.io/aquasec/trivy-db:2`, downloaded 2026-10-27T06:18Z |

Targets:
- **before-image** `php:7.1-cli` (PHP 7.1.33, Debian 10) — the baseline runtime.
- **after-image** `morgue-php:local` built from this branch's `Dockerfile` (PHP 8.4.27, Debian 13).
- **before-app** the original dependency set resolved for PHP 7.1.33 (`slim/slim 2.*`,
  `twig/twig 1.*`, `sabre/dav ~2.1.1`, `phpunit ^6`) → slim 2.6.3, twig v1.43.1, sabre/dav 2.1.11,
  phpunit 6.5.14: exactly the baseline versions. `composer update --no-install --no-security-blocking`.
- **after-app** this branch's `composer.json` + committed `composer.lock`.

## Results

| Target | Grype total (C/H) | Grype PHP2Shell | Trivy total (C/H) | Trivy PHP2Shell | Twig (Grype / Trivy) |
|---|---|---|---|---|---|
| before-image | 1058 (42/273) | **CVE-2026-109619** on `php-cli 7.1.33` (binary, CPE match) | 1789 (50/671) | **none — PHP not detected** | – |
| after-image  | 992 (19/142)  | none | 1848 (2/118) | none (PHP not detected) | – |
| before-app   | 14 (1/3)      | n/a  | 16 (4/5) | n/a | 14 / 16 (Trivy: 4 critical, 5 high) |
| after-app    | **0**         | n/a  | **0**    | n/a | **0 / 0** (Twig removed) |

Runtime policy (`docs/php84-spike/harness/policy-php-version.sh`, asks the interpreter):

```
PASS morgue-php:local runs PHP 8.4.27 (>= 8.4.27)
FAIL php:7.1-cli runs PHP 7.1.33 (< 8.4.27): PHP2Shell CVE-2026-109618/109619 not fixed
```

## What this shows

1. **Trivy cannot see the PHP runtime** in either official php image (PHP is compiled from source,
   so there is no dpkg entry). Its "no PHP2Shell" verdict is identical for the vulnerable and the
   fixed image, so it means nothing. This matches the earlier GitLab Container Scanning/SBOM finding.
2. **Syft's binary classifier does find `php-cli`** (`/usr/local/bin/php`, version from the binary),
   so Grype matches PHP via CPE `cpe:2.3:a:php:php:7.1.33`. Use Syft+Grype, not Trivy, to *detect*
   a source-built runtime.
3. **But NVD's ranges under-report EOL branches.** In Grype's DB the NVD record for
   CVE-2026-109618 lists `cpe:php:php >= 7.3.0, < 8.2.35` (+ 8.3/8.4/8.5 ranges), and
   CVE-2026-109619 lists `>= 5.4.0, < 8.2.35`. So PHP 7.1.33 matches only **109619**; 109618 is
   silently missed because nobody analysed EOL 7.1/7.2. "Not matched" does not mean "not affected"
   for an EOL runtime that will never get a fix.
4. The only reliable gate is a **runtime policy check** on the version the interpreter reports,
   against the vendor's fixed releases (8.2.35 / 8.3.36 / 8.4.27 / 8.5.12), plus "EOL branch ⇒ fail".
5. App dependencies: Twig 1.x was the whole app-level finding set (16 Trivy / 14 Grype) and it was
   unused. After the upgrade, Grype and Trivy report 0 for the lockfile; `composer audit` also
   reports none. Remaining image findings are Debian 13 base packages (2 critical / 118 high in
   Trivy, none PHP-related), a separate base-image patching concern.
6. Not covered by any scanner: slim/slim 2.6.3 is abandoned (no PHP 8 release) but carries no
   advisory, and `composer audit --abandoned=report` doesn't flag it, because the package name is
   alive (v4).

## Commands

```
docker save php:7.1-cli -o before-image.tar; docker save morgue-php:local -o after-image.tar
syft docker-archive:after-image.tar -o table            # shows: php-cli 8.4.27 binary
grype db update; grype docker-archive:before-image.tar -o json
grype dir:after-app -o json                              # composer.lock
grype db search --vuln CVE-2026-109618 -o json           # inspect NVD CPE ranges
trivy image --input before-image.tar --scanners vuln -f json
trivy fs after-app --scanners vuln -f json
docs/php84-spike/harness/policy-php-version.sh morgue-php:local 8.4.27
```
(Behind the sandbox egress proxy, containers ran with `--network host`, `HTTPS_PROXY` and the
proxy CA as `SSL_CERT_FILE`; Grype's cache volume must be mounted at `/.cache/grype`.)
