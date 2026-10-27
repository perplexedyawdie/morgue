# Runbook: PHP runtime upgrade for a legacy application

> SKELETON — refined as the morgue spike progresses (see JOURNAL.md).

Each section is a work-item template a planning agent can turn into one issue
for one specialist agent.

1. Baseline and acceptance harness
2. Detect and confirm exposure (SBOM / Grype / runtime policy)
3. Static compatibility scan
4. Runtime bump
5. Dependency resolution and lockfile
6. Framework / vendor shims
7. App code fixes (driven by tests and runtime errors)
8. Test-suite migration
9. Security re-verification
10. Release / deploy readiness

## Pitfalls
- TBD
