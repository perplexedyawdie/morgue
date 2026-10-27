#!/usr/bin/env bash
# Web-path deprecation/warning audit at full E_ALL.
#
# Why: Slim 2's error handler throws on every enabled level and silently swallows the rest,
# so with the accepted runtime config (E_ALL & ~E_DEPRECATED) app-code deprecations on the web
# path are invisible, and at E_ALL Slim's own deprecations kill every request. This script
# patches the LOCAL vendor copy of Slim::handleErrors() for the duration of the run so that
# deprecations are logged and execution continues, serves at E_ALL, exercises every route
# (GET + writes), restores the vendor file, and reports anything outside vendor/.
#
#   docs/php84-spike/harness/audit-web.sh      (runs run.sh first with KEEP=1)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
OUT="$HERE/out"; PHP_IMAGE="${PHP_IMAGE:-morgue-php:local}"; APP_PORT="${APP_PORT:-8000}"
BASE="http://127.0.0.1:$APP_PORT"; SLIM="$REPO/vendor/slim/slim/Slim/Slim.php"

KEEP=1 SKIP_BUILD="${SKIP_BUILD:-1}" SKIP_COMPOSER="${SKIP_COMPOSER:-1}" "$HERE/run.sh" > "$OUT/../audit-run.log" 2>&1 \
  || { tail -20 "$OUT/../audit-run.log"; echo "run.sh failed"; exit 1; }
mv "$OUT/../audit-run.log" "$OUT/audit-run.log"

cp "$SLIM" "$OUT/Slim.php.orig"
restore() { cp "$OUT/Slim.php.orig" "$SLIM"; docker rm -f morgue-harness-app morgue-harness-db >/dev/null 2>&1; }
trap restore EXIT
docker run --rm -v "$REPO:/app" -w /app "$PHP_IMAGE" php -r '
  $f = "vendor/slim/slim/Slim/Slim.php"; $s = file_get_contents($f);
  $needle = "        if (!(\$errno & error_reporting())) {";
  $add = "        if (\$errno & (E_DEPRECATED | E_USER_DEPRECATED)) { error_log(\"PHP Deprecated:  \$errstr in \$errfile on line \$errline\"); return true; } // AUDIT\n";
  if (strpos($s, $needle) === false) { fwrite(STDERR, "patch point not found\n"); exit(1); }
  file_put_contents($f, str_replace($needle, $add.$needle, $s));' || exit 1

docker rm -f morgue-harness-app >/dev/null 2>&1
: > "$OUT/php.log"
docker run -d --name morgue-harness-app --network host -v "$REPO:/app" -w /app/htdocs \
  -e MORGUE_ENVIRONMENT=development "$PHP_IMAGE" php -d error_reporting=E_ALL -d display_errors=Off \
  -d log_errors=On -d error_log=/app/docs/php84-spike/harness/out/php.log \
  -d include_path=".:/app:/app/features" -S "127.0.0.1:$APP_PORT" >/dev/null
for i in $(seq 1 30); do curl -s -o /dev/null "$BASE/ping" && break; sleep 0.5; done

: > "$OUT/audit-requests.txt"
req() { # method path [curl data args...]
  local m=$1 p=$2; shift 2
  local code; code=$(curl -s -o "$OUT/audit.body" -w '%{http_code}' -X "$m" -H "Referer: $BASE/" "$BASE$p" "$@")
  local err; err=$(sed -e 's/<[^>]*>/ /g' "$OUT/audit.body" | tr -s ' \n' | grep -oE 'Message: .{0,160}' | head -1)
  printf '%s %-6s %s %s\n' "$code" "$m" "$p" "$err" | tee -a "$OUT/audit-requests.txt"
}
EV="-d start_date=10/27/2026 -d start_time=10:00 -d end_date=10/27/2026 -d end_time=11:00 -d detect_date=10/27/2026 -d detect_time=10:05 -d timezone=UTC -d severity=2 -d problem_type=Software -d impact_type=Users -d incident_cause=Change -d subsystem=web -d owner_team=sre"
req POST /events -d title=audit-one $EV
req POST /events -d title=audit-two $EV
for p in / /anniversary /anniversary/mail /api/anniversary /report /search "/search?q=audit" /ping \
         /events/1 /events/1/summary /events/1/tldr /events/1/why_surprised /events/1/lock \
         /events/1/images /events/1/tickets /events/1/forum_links /events/1/slack-channels \
         /features/slack/js/slack.js /events/999 /events/999/lock /history/999/999; do req GET "$p"; done
req PUT    /events/1 -d title=audit-renamed -d summary=s -d why_surprised=w -d tldr=t -d severity=3 \
           -d start_date=10/26/2026 -d start_time=09:00 -d end_time=12:00 -d detect_time=09:30 -d timezone=UTC \
           -d problem_type=Hardware -d meeting_notes_link=http://example.invalid/notes
req POST   /events/1/history -d action=edit -d summary=s2 -d why_surprised=w2
req GET    /history/1/1
req POST   /events/1/tags -d 'tags=Alpha, beta'
req DELETE /events/1/tags/1
req POST   /events/1/forum_links -d forum_link=http://example.invalid/f -d forum_comment=c
req DELETE /events/1/forum_links/1
req POST   /events/1/images -d images=http://example.invalid/a.png
req DELETE /events/1/images/1
req POST   /events/1/slack-channels -d channel_id=C1 -d channel_name=incident
req DELETE /events/1/slack-channels/1
req POST   /events/1/tickets -d tickets=FOO-1
req DELETE /events/1/tickets/1
req POST   /timezone -d timezone=UTC
req DELETE /events/2
req GET    /events/2/undelete
req GET    /events/1

sleep 0.5
echo; echo "== PHP log entries outside vendor/ (E_ALL):"
grep -E 'PHP ' "$OUT/php.log" | grep -v '/app/vendor/' | sed 's/^\[[^]]*\] //' | sort | uniq -c | sort -rn | tee "$OUT/audit-findings.txt"
echo "== vendor entries (accepted):"; grep -E 'PHP ' "$OUT/php.log" | grep '/app/vendor/' | sed 's/^\[[^]]*\] //' | sort | uniq -c | sort -rn | head -30
n=$(wc -l < "$OUT/audit-findings.txt"); f=$(grep -c '^5' "$OUT/audit-requests.txt")
echo "== app findings: $n, 5xx responses: $f"
[ "$n" = 0 ] && [ "$f" = 0 ]
