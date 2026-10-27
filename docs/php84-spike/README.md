# PHP 7.1 → 8.4.27 upgrade spike (PHP2Shell)

| File | What |
|---|---|
| `RUNBOOK.md` | General PHP runtime upgrade runbook: 10 work-item templates + pitfalls |
| `JOURNAL.md` | Chronological log: every command, error, root cause, fix, category, time; summary at the end |
| `static-scan.txt` | Pre-change static scan (php -l, PHPCompatibility 10) = predicted breakage; after-scan + predicted vs actual |
| `SECURITY-VERIFICATION.md` | Syft/Grype/Trivy before vs after, runtime policy |
| `harness/run.sh` | One-command acceptance harness (Docker: MariaDB, dev server smoke, phpunit) |
| `harness/audit-web.sh` | Web-path E_ALL deprecation/warning audit over every route |
| `harness/policy-php-version.sh` | Runtime policy: interpreter version ≥ fixed release |

Quick start: `docs/php84-spike/harness/run.sh` → `HARNESS GREEN`.
