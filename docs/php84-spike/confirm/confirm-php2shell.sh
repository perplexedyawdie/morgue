#!/usr/bin/env bash
# confirm-php2shell.sh — confirm whether a LOCAL morgue runtime image is susceptible to
# PHP2Shell (CVE-2026-109618 / CVE-2026-109619). Operationalizes RUNBOOK WI-2/WI-9 as a
# runnable, authorized self-test. Local disposable containers only.
#
#   docs/php84-spike/confirm/confirm-php2shell.sh
#   PHP_IMAGE=morgue-php:vuln docs/php84-spike/confirm/confirm-php2shell.sh
#   docs/php84-spike/confirm/confirm-php2shell.sh --active --i-understand-this-crashes-workers
#
# Exit code (the single machine-readable verdict):
#   0  FIXED         — runtime is at/above the fixed release on its branch
#   1  SUSCEPTIBLE   — below the fixed patch, or on an end-of-life branch
#   2  INCONCLUSIVE  — could not read a version / misuse / guardrail refusal
#
# Two layers, authoritative first:
#   Layer 1 (always, NON-DESTRUCTIVE): read the PHP version two ways and apply the
#     per-branch fixed-release map plus an EOL-branch rule. This is the verdict.
#   Layer 2 (--active, DISRUPTIVE, opt-in): run the vendored assetnote scanner's OOM
#     probe against a throwaway container, purely to corroborate. It can crash workers,
#     so it runs only against a fresh container this script created and then destroys.
#
# The script OWNS the target. It starts a container from $PHP_IMAGE serving the repo on a
# loopback port it chooses; there is deliberately no --url, so it cannot be pointed at an
# arbitrary host.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
OUT="$HERE/out"
SCANNER="$HERE/vendor/php2shell-scanner/scanner.py"

PHP_IMAGE="${PHP_IMAGE:-morgue-php:local}"
PORT="${PORT:-8099}"
MEMORY_LIMIT="${MEMORY_LIMIT:-512M}"
ACTIVE=0
CONFIRM=0

# First release on each still-supported branch that carries the PHP2Shell fix. Identical to
# the vendored scanner's FIXED_VERSIONS map and to RUNBOOK <FIXED_MIN>. A branch NOT in this
# map is end-of-life: susceptible forever, because it will never be patched.
declare -A FIXED=( [8.2]=35 [8.3]=36 [8.4]=27 [8.5]=12 )

usage() { sed -n '2,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --active) ACTIVE=1 ;;
    --i-understand-this-crashes-workers) CONFIRM=1 ;;
    --memory-limit) MEMORY_LIMIT="${2:?}"; shift ;;
    --port) PORT="${2:?}"; shift ;;
    -h|--help) usage; exit 2 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

mkdir -p "$OUT"
CT="morgue-confirm-$$"
CONFIG="$OUT/development.json"
PROBE_ROOT="$OUT/probe-docroot"
VERDICT="INCONCLUSIVE"; EXIT=2
cleanup() { docker rm -f "$CT" >/dev/null 2>&1 || true; }
trap cleanup EXIT

die() { echo "ERROR: $*" >&2; exit 2; }

# Layer 1 black-box target: a disposable morgue server from $PHP_IMAGE. morgue's index.php
# require_once's repo-relative paths (needs the README include_path) and die()s early unless
# config/development.json exists. A valid config (the DB need not be reachable: /ping doesn't
# touch it) gets it serving so we can read the X-Powered-By morgue itself emits.
start_morgue() {
  docker rm -f "$CT" >/dev/null 2>&1 || true
  docker run -d --name "$CT" -p "127.0.0.1:$PORT:$PORT" \
    -v "$REPO:/app:ro" -v "$CONFIG:/app/config/development.json:ro" -w /app/htdocs \
    -e MORGUE_ENVIRONMENT=development "$PHP_IMAGE" \
    php -d memory_limit="$MEMORY_LIMIT" -d expose_php=On -d include_path=".:/app:/app/features" \
    -S "0.0.0.0:$PORT" >/dev/null || die "failed to start morgue container"
  # morgue may answer /ping with 200 (patched) or 500 (older PHP trips the lock's platform_check);
  # either way it emits X-Powered-By, which is all Layer 1 reads.
  for _ in $(seq 1 40); do curl -s -o /dev/null "$BASE/ping" && return 0; sleep 0.3; done
  die "morgue target did not come up on $BASE"
}

# Layer 2 probe target: a minimal PHP endpoint on the SAME image. PHP2Shell is a bug in PHP's
# multipart parser (request startup), not in morgue, so the faithful way to exercise the runtime
# is any PHP script that returns a healthy control. Using the app's own index.php is unreliable
# here: a vulnerable older PHP is refused by the committed lock's composer platform_check before
# the request runs, so its control would be a useless 5xx. The minimal endpoint sidesteps that
# and tests exactly the runtime the image ships.
start_probe() {
  mkdir -p "$PROBE_ROOT"
  printf '<?php\nhttp_response_code(200);\nheader("Content-Type: text/plain");\necho "probe-ok";\n' > "$PROBE_ROOT/probe.php"
  docker rm -f "$CT" >/dev/null 2>&1 || true
  docker run -d --name "$CT" -p "127.0.0.1:$PORT:$PORT" -v "$PROBE_ROOT:/probe:ro" -w /probe \
    "$PHP_IMAGE" php -d memory_limit="$MEMORY_LIMIT" -d expose_php=On -S "0.0.0.0:$PORT" -t /probe >/dev/null \
    || die "failed to start probe container"
  for _ in $(seq 1 40); do curl -s -o /dev/null "$BASE/probe.php" && return 0; sleep 0.3; done
  die "probe target did not come up on $BASE"
}

# ---- preflight ------------------------------------------------------------------------
docker info >/dev/null 2>&1 || die "docker daemon not reachable"
docker image inspect "$PHP_IMAGE" >/dev/null 2>&1 \
  || die "image '$PHP_IMAGE' not found; build it first (docs/php84-spike/harness/run.sh, or the vuln twin)"
[[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || die "bad --port '$PORT'"

# Target URL is always loopback and always a port we publish. Guardrail, belt and braces.
HOST=127.0.0.1
BASE="http://$HOST:$PORT"
case "$HOST" in 127.0.0.1|::1|localhost) ;; *) die "refusing non-loopback target $HOST" ;; esac

# ---- verdict helper -------------------------------------------------------------------
# echoes "FIXED"|"SUSCEPTIBLE"|"UNKNOWN<reason>" for a dotted PHP version string
version_verdict() {
  local ver="$1" major minor patch branch floor
  [[ "$ver" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+) ]] || { echo "UNKNOWN unparseable '$ver'"; return; }
  major="${BASH_REMATCH[1]}"; minor="${BASH_REMATCH[2]}"; patch="${BASH_REMATCH[3]}"
  branch="$major.$minor"
  floor="${FIXED[$branch]:-}"
  if [ -z "$floor" ]; then
    echo "SUSCEPTIBLE branch $branch is end-of-life (not in the fixed-release map); it will never be patched"
  elif [ "$patch" -ge "$floor" ]; then
    echo "FIXED $branch.$patch >= fixed floor $branch.$floor"
  else
    echo "SUSCEPTIBLE $branch.$patch < fixed floor $branch.$floor"
  fi
}

# =======================================================================================
# Layer 1 — runtime-version policy (authoritative, non-destructive)
# =======================================================================================
echo "== Layer 1: runtime-version policy (non-destructive)"
echo "   image: $PHP_IMAGE"

# Authoritative: ask the interpreter directly. No server, no request.
AUTH_VER="$(docker run --rm "$PHP_IMAGE" php -r 'echo PHP_VERSION;' 2>/dev/null)"
[ -n "$AUTH_VER" ] || die "could not read PHP_VERSION from image $PHP_IMAGE"
echo "   interpreter PHP_VERSION = $AUTH_VER   (docker run php -r)"

# One valid config for every disposable instance this run starts (see start_target).
docker run --rm -v "$REPO:/app:ro" -w /app "$PHP_IMAGE" php -r '
  $c = json_decode(file_get_contents("config/example.json"), true);
  $c["environment"] = "development";
  $c["database"]["mysqlhost"] = "127.0.0.1"; $c["database"]["mysqlport"] = 33306;
  echo json_encode($c, JSON_PRETTY_PRINT|JSON_UNESCAPED_SLASHES);' > "$CONFIG" 2>/dev/null
[ -s "$CONFIG" ] || die "could not generate config/development.json from config/example.json"

# Black-box corroboration: X-Powered-By from a short-lived loopback morgue server.
start_morgue
XPB="$(curl -sI "$BASE/ping" 2>/dev/null | tr -d '\r' | awk -F': ' 'tolower($1)=="x-powered-by"{print $2}')"
cleanup
if [ -n "$XPB" ]; then
  echo "   black-box X-Powered-By = $XPB"
else
  echo "   black-box X-Powered-By = (absent; expose_php likely Off — rely on the interpreter read)"
fi

read -r L1 L1REASON <<<"$(version_verdict "$AUTH_VER")"
echo "   verdict: $L1 — $L1REASON"
case "$L1" in
  FIXED)       VERDICT=FIXED; EXIT=0 ;;
  SUSCEPTIBLE) VERDICT=SUSCEPTIBLE; EXIT=1 ;;
  *)           VERDICT=INCONCLUSIVE; EXIT=2 ;;
esac

SCAN_VERDICT="not run"; SCAN_REASON="--active not requested"

# =======================================================================================
# Layer 2 — active OOM probe (opt-in, disruptive, local disposable only)
# =======================================================================================
if [ "$ACTIVE" = 1 ]; then
  [ "$CONFIRM" = 1 ] || die "--active requires --i-understand-this-crashes-workers (the probe OOMs/crashes the PHP worker)"
  command -v uv >/dev/null 2>&1 || die "--active needs 'uv' to run the vendored scanner"
  [ -f "$SCANNER" ] || die "vendored scanner missing: $SCANNER"
  echo
  echo "== Layer 2: active PHP2Shell OOM probe (DISRUPTIVE) against a throwaway container"
  echo "   exercises the image's PHP runtime via a minimal endpoint (the bug is in PHP's parser,"
  echo "   not morgue); sends 1/8/20 MiB nested-multipart bodies and WILL crash the worker"

  # Fresh container: the probe crashes it, so never reuse one that must keep serving.
  start_probe

  SCAN_JSON="$OUT/scan-$(date +%Y%m%dT%H%M%SZ).json"
  # --all-results: the scanner otherwise saves only VULNERABLE hosts; we want the verdict either way.
  uv run "$SCANNER" -u "$BASE" --path /probe.php --all-results --no-color \
      --timeout 180 -o "$SCAN_JSON" > "$OUT/scan.log" 2>&1 || true
  cleanup

  if [ -s "$SCAN_JSON" ]; then
    read -r SCAN_VERDICT SCAN_REASON <<<"$(
      python3 -I -c "import json,sys
d=json.load(open(sys.argv[1])).get('results',[])
if not d: print('NO_RESULT (no vulnerable host saved; probe did not crash the worker)'); raise SystemExit
r=d[0]; print(r.get('verdict','?'), (r.get('reason') or '').replace(chr(10),' '))" "$SCAN_JSON" 2>/dev/null
    )"
    echo "   scanner verdict: $SCAN_VERDICT — $SCAN_REASON"
    echo "   scanner output: $SCAN_JSON"
  else
    SCAN_VERDICT="NO_RESULT"; SCAN_REASON="scanner produced no JSON (see $OUT/scan.log)"
    echo "   scanner verdict: NO_RESULT — $SCAN_REASON"
  fi

  # The version policy is authoritative; the probe only corroborates. Flag disagreement.
  if [ "$L1" = FIXED ] && [ "$SCAN_VERDICT" = VULNERABLE ]; then
    echo "   NOTE: probe says VULNERABLE but the version is patched — likely the low-memory_limit"
    echo "         false positive the scanner's own README warns about. Version policy wins: FIXED."
  elif [ "$L1" = SUSCEPTIBLE ] && [ "$SCAN_VERDICT" = VULNERABLE ]; then
    echo "   probe corroborates the version verdict."
  elif [ "$L1" = SUSCEPTIBLE ] && [ "$SCAN_VERDICT" != VULNERABLE ]; then
    echo "   NOTE: version says SUSCEPTIBLE; probe did not crash this SAPI. Version policy wins: SUSCEPTIBLE."
  fi
fi

# ---- single machine-readable verdict --------------------------------------------------
RESULT_JSON="$OUT/confirm-$(date +%Y%m%dT%H%M%SZ).json"
python3 -I -c "import json,sys
json.dump({
 'verdict': sys.argv[1], 'exit_code': int(sys.argv[2]), 'image': sys.argv[3],
 'php_version': sys.argv[4], 'x_powered_by': sys.argv[5] or None,
 'layer1': {'verdict': sys.argv[6], 'reason': sys.argv[7]},
 'layer2': {'active': bool(int(sys.argv[8])), 'scanner_verdict': sys.argv[9], 'scanner_reason': sys.argv[10]},
 'cves': ['CVE-2026-109618','CVE-2026-109619'],
}, open(sys.argv[11],'w'), indent=2)" \
  "$VERDICT" "$EXIT" "$PHP_IMAGE" "$AUTH_VER" "$XPB" "$L1" "$L1REASON" "$ACTIVE" "$SCAN_VERDICT" "$SCAN_REASON" "$RESULT_JSON"

echo
echo "== VERDICT: $VERDICT   (exit $EXIT)   image $PHP_IMAGE, PHP $AUTH_VER"
echo "   $RESULT_JSON"
exit "$EXIT"
