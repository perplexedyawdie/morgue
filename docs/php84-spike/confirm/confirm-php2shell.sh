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
# Low PHP memory_limit used only by the fallback evidence pass (5. below): forces PHP's own
# memory-exhausted fatal to be raised and logged even when the 512M run crashes without flushing
# it. A low limit also fatals on a patched build, so this pass demonstrates the mechanism, it does
# not discriminate fixed vs vulnerable.
MEMORY_LIMIT_EVIDENCE="${MEMORY_LIMIT_EVIDENCE:-128M}"
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
EVID="$OUT/evidence"                 # bind-mounted into the probe container as /evidence
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
# start_probe <php_memory_limit> <container_memory>
# PHP's memory_limit governs the fatal; the container --memory ceiling sits just above it so
# `docker stats` MemPerc is meaningful and the kernel does not OOM-kill before PHP's own limit.
# error_log goes to the bind-mounted /evidence so the fatal survives a worker crash.
start_probe() {
  local php_ml="${1:-$MEMORY_LIMIT}" ct_mem="${2:-1g}"
  mkdir -p "$PROBE_ROOT" "$EVID"
  printf '<?php\nhttp_response_code(200);\nheader("Content-Type: text/plain");\necho "probe-ok";\n' > "$PROBE_ROOT/probe.php"
  docker rm -f "$CT" >/dev/null 2>&1 || true
  docker run -d --name "$CT" --memory "$ct_mem" -p "127.0.0.1:$PORT:$PORT" \
    -v "$PROBE_ROOT:/probe:ro" -v "$EVID:/evidence" -w /probe "$PHP_IMAGE" \
    php -d memory_limit="$php_ml" -d expose_php=On \
        -d log_errors=On -d display_errors=On -d error_log=/evidence/php-error.log \
    -S "0.0.0.0:$PORT" -t /probe >/dev/null \
    || die "failed to start probe container"
  for _ in $(seq 1 40); do curl -s -o /dev/null "$BASE/probe.php" && return 0; sleep 0.3; done
  die "probe target did not come up on $BASE"
}

# Peak resident memory of the probe container, read from the kernel's own high-water mark so a
# sub-second OOM is not missed (unlike polling `docker stats`). cgroup v1 then v2 path; empty if
# the container already exited (crashed) and can no longer be exec'd into.
peak_bytes() {
  docker exec "$CT" cat /sys/fs/cgroup/memory/memory.max_usage_in_bytes 2>/dev/null \
    || docker exec "$CT" cat /sys/fs/cgroup/memory.peak 2>/dev/null || echo ""
}
limit_bytes() {
  docker exec "$CT" cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null \
    || docker exec "$CT" cat /sys/fs/cgroup/memory.max 2>/dev/null || echo ""
}

# Grep the captured server-side channels for PHP's memory-exhausted fatal. Echoes the first
# matching line, or empty. The `in Unknown` hallmark (parse-time, no userland frame) is preferred.
find_oom_fatal() {
  local f line
  for f in "$EVID/php-error.log" "$EVID/stderr.log"; do
    [ -s "$f" ] || continue
    line="$(grep -aE 'Allowed memory size of [0-9]+ bytes exhausted' "$f" | grep -a 'Unknown' | head -1)"
    [ -z "$line" ] && line="$(grep -aE 'Allowed memory size of [0-9]+ bytes exhausted' "$f" | head -1)"
    [ -n "$line" ] && { echo "$line"; return 0; }
  done
  return 1
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
# oom_evidence defaults (populated by --active)
OOM_FATAL=""; OOM_CHANNEL=""; MEM_PEAK="n/a"; MEM_PERC_PEAK="n/a"
CONTAINER_STATE="n/a"; EXIT_CODE="n/a"; OOM_KILLED="n/a"; SERVED_AFTER="n/a"; EVIDENCE_PASS_ML=""

# Run the scanner's probe suite against the live $CT; echo "<verdict> <reason>".
run_scanner() {
  local json="$1"
  uv run "$SCANNER" -u "$BASE" --path /probe.php --all-results --no-color \
      --timeout 180 -o "$json" > "$OUT/scan.log" 2>&1 || true
  if [ -s "$json" ]; then
    python3 -I -c "import json,sys
d=json.load(open(sys.argv[1])).get('results',[])
if not d: print('NO_RESULT (no vulnerable host saved; probe did not crash the worker)'); raise SystemExit
r=d[0]; print(r.get('verdict','?'), (r.get('reason') or '').replace(chr(10),' '))" "$json" 2>/dev/null
  else
    echo "NO_RESULT scanner produced no JSON (see $OUT/scan.log)"
  fi
}

# =======================================================================================
# Layer 2 — active OOM probe + direct evidence capture (opt-in, disruptive, local only)
# =======================================================================================
if [ "$ACTIVE" = 1 ]; then
  [ "$CONFIRM" = 1 ] || die "--active requires --i-understand-this-crashes-workers (the probe OOMs/crashes the PHP worker)"
  command -v uv >/dev/null 2>&1 || die "--active needs 'uv' to run the vendored scanner"
  [ -f "$SCANNER" ] || die "vendored scanner missing: $SCANNER"
  echo
  echo "== Layer 2: active PHP2Shell OOM probe (DISRUPTIVE) against a throwaway container"
  echo "   exercises the image's PHP runtime via a minimal endpoint (the bug is in PHP's parser,"
  echo "   not morgue); sends 1/8/20 MiB nested-multipart bodies and WILL crash the worker"

  rm -rf "$EVID"; mkdir -p "$EVID"      # negative-control integrity: start from empty evidence
  SCAN_JSON="$OUT/scan-$(date +%Y%m%dT%H%M%SZ).json"

  # Fresh container: the probe crashes it, so never reuse one that must keep serving.
  start_probe "$MEMORY_LIMIT" 1g
  read -r SCAN_VERDICT SCAN_REASON <<<"$(run_scanner "$SCAN_JSON")"

  # Capture the holistic event BEFORE teardown (while $CT still exists).
  PEAK="$(peak_bytes)"; LIMIT="$(limit_bytes)"
  read -r MEM_PEAK MEM_PERC_PEAK <<<"$(
    python3 -I -c "import sys
p=sys.argv[1]; l=sys.argv[2]
if not p.strip().isdigit(): print('n/a n/a'); raise SystemExit
pb=int(p); print('%.0fMiB' % (pb/1048576), ('%.0f%%'%(pb*100/int(l)) if l.strip().isdigit() and int(l)>0 else 'n/a'))" "$PEAK" "$LIMIT" 2>/dev/null || echo 'n/a n/a')"
  docker stats --no-stream --format '{{.MemUsage}} | {{.MemPerc}} | PIDs {{.PIDs}}' "$CT" > "$EVID/stats.log" 2>/dev/null || true
  SERVED_AFTER="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$BASE/probe.php" 2>/dev/null || echo 000)"
  docker logs "$CT" > "$EVID/stderr.log" 2>&1 || true
  read -r CONTAINER_STATE EXIT_CODE OOM_KILLED <<<"$(
    docker inspect -f '{{.State.Status}} {{.State.ExitCode}} {{.State.OOMKilled}}' "$CT" 2>/dev/null || echo 'gone - -')"
  docker rm -f "$CT" >/dev/null 2>&1 || true

  echo "   scanner verdict: $SCAN_VERDICT — $SCAN_REASON"
  echo "   scanner output: $SCAN_JSON"

  OOM_FATAL="$(find_oom_fatal || true)"
  [ -n "$OOM_FATAL" ] && OOM_CHANNEL="php error_log/stderr (512M run)"

  # Fallback (5.): no literal fatal flushed at 512M but the scanner saw a crash → force PHP's own
  # memory_limit fatal at a low limit purely to capture the mechanism. Does NOT discriminate.
  if [ -z "$OOM_FATAL" ] && [ "$SCAN_VERDICT" = VULNERABLE ]; then
    echo "   no literal fatal flushed at $MEMORY_LIMIT; running low-limit evidence pass at $MEMORY_LIMIT_EVIDENCE"
    start_probe "$MEMORY_LIMIT_EVIDENCE" 512m
    run_scanner "$OUT/scan-evidence.json" >/dev/null
    docker logs "$CT" >> "$EVID/stderr.log" 2>&1 || true
    docker rm -f "$CT" >/dev/null 2>&1 || true
    OOM_FATAL="$(find_oom_fatal || true)"
    [ -n "$OOM_FATAL" ] && { OOM_CHANNEL="php error_log/stderr (low-limit $MEMORY_LIMIT_EVIDENCE pass)"; EVIDENCE_PASS_ML="$MEMORY_LIMIT_EVIDENCE"; }
  fi

  echo
  echo "   -- DIRECT OOM EVIDENCE --"
  echo "   container memory peak: $MEM_PEAK ($MEM_PERC_PEAK)   state: $CONTAINER_STATE exit=$EXIT_CODE OOMKilled=$OOM_KILLED"
  echo "   served after probe:    HTTP $SERVED_AFTER $([ "$SERVED_AFTER" = 200 ] && echo '(still serving)' || echo '(stopped serving)')"
  if [ -n "$OOM_FATAL" ]; then
    echo "   PHP fatal captured:    $OOM_FATAL"
    echo "   channel:               $OOM_CHANNEL"
  else
    echo "   PHP fatal captured:    none (see $EVID/ — on a patched build this is expected)"
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
a=sys.argv
json.dump({
 'verdict': a[1], 'exit_code': int(a[2]), 'image': a[3],
 'php_version': a[4], 'x_powered_by': a[5] or None,
 'layer1': {'verdict': a[6], 'reason': a[7]},
 'layer2': {'active': bool(int(a[8])), 'scanner_verdict': a[9], 'scanner_reason': a[10]},
 'oom_evidence': ({
   'fatal_captured': bool(a[12]), 'fatal_line': a[12] or None, 'channel': a[13] or None,
   'mem_peak': a[14], 'mem_perc_peak': a[15],
   'container_state': a[16], 'exit_code': a[17], 'oom_killed': a[18],
   'served_after_http': a[19],
   'evidence_pass_memory_limit': a[20] or None,
 } if bool(int(a[8])) else None),
 'cves': ['CVE-2026-109618','CVE-2026-109619'],
}, open(a[11],'w'), indent=2)" \
  "$VERDICT" "$EXIT" "$PHP_IMAGE" "$AUTH_VER" "$XPB" "$L1" "$L1REASON" "$ACTIVE" "$SCAN_VERDICT" "$SCAN_REASON" "$RESULT_JSON" \
  "$OOM_FATAL" "$OOM_CHANNEL" "$MEM_PEAK" "$MEM_PERC_PEAK" "$CONTAINER_STATE" "$EXIT_CODE" "$OOM_KILLED" "$SERVED_AFTER" "$EVIDENCE_PASS_ML"

echo
echo "== VERDICT: $VERDICT   (exit $EXIT)   image $PHP_IMAGE, PHP $AUTH_VER"
echo "   $RESULT_JSON"
exit "$EXIT"
