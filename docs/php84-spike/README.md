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
| `tool-eval/RESULTS.md` | Measured: what PHPStan 2.3.2 / Rector 2.8.1 would have caught vs the hand fixes |
| `tool-eval/measure-tools.sh` | Reproduces that measurement (offline analysis, read-only copy of the pre-fix tree) |
| `confirm/SKILL.md` | Skill: confirm a local image's PHP2Shell susceptibility (CVE-2026-109618/-109619) |
| `confirm/confirm-php2shell.sh` | Loopback-only: version policy (always) + opt-in disruptive OOM probe |
| `confirm/vendor/php2shell-scanner/` | Pinned MIT copy of assetnote/php2shell-scanner (the detector) |

Quick start: `docs/php84-spike/harness/run.sh` → `HARNESS GREEN`;
`docs/php84-spike/confirm/confirm-php2shell.sh` → `VERDICT: FIXED`.
