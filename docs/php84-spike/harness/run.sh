#!/usr/bin/env bash
# Morgue acceptance harness: one command, exit 0 = green.
#
#   docs/php84-spike/harness/run.sh            # build image, DB, composer install, smoke, phpunit
#   SKIP_BUILD=1 SKIP_COMPOSER=1 ./run.sh       # reuse image and vendor/
#   KEEP=1 ./run.sh                             # leave DB + server running afterwards
#
# Needs only docker (+ curl on the host). All PHP runs inside the image built from
# the repo-root Dockerfile, so the PHP version under test is whatever that pins.
#
# Knobs (env):
#   PHP_IMAGE        image tag to build/use              (default morgue-php:local)
#   DB_IMAGE         MariaDB image                        (default mariadb:10.4)
#   DB_PORT          host port for MariaDB                (default 33306)
#   APP_PORT         host port for the dev server         (default 8000)
#   ERROR_REPORTING  error_reporting for server + phpunit (default E_ALL)
#   MIN_PHP          runtime policy: fail if PHP_VERSION < this (default 8.4.27)
#   PHPUNIT_FILTER   phpunit --filter (default excludes the flaky httpbin CurlClient tests)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
OUT="$HERE/out"
PHP_IMAGE="${PHP_IMAGE:-morgue-php:local}"
DB_IMAGE="${DB_IMAGE:-mariadb:10.4}"
DB_PORT="${DB_PORT:-33306}"
APP_PORT="${APP_PORT:-8000}"
ERROR_REPORTING="${ERROR_REPORTING:-E_ALL}"
MIN_PHP="${MIN_PHP:-8.4.27}"
PHPUNIT_FILTER="${PHPUNIT_FILTER:-/^(?!.*CurlClient)/}"
DB_CT=morgue-harness-db
APP_CT=morgue-harness-app
BASE="http://127.0.0.1:$APP_PORT"

mkdir -p "$OUT"; rm -f "$OUT"/*
FAILS=0
log()  { printf '\n== %s\n' "$*"; }
ok()   { printf '  PASS %s\n' "$*"; }
bad()  { printf '  FAIL %s\n' "$*"; FAILS=$((FAILS+1)); }

cleanup() {
  [ "${KEEP:-0}" = 1 ] && return
  docker logs "$APP_CT" > "$OUT/server.log" 2>&1 || true
  docker rm -f "$APP_CT" "$DB_CT" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Pass the host's egress proxy + CA bundle into containers when present
# (sandboxes / corporate networks); harmless elsewhere.
NET_ARGS=(--network host)
for v in HTTPS_PROXY https_proxy NO_PROXY no_proxy; do
  [ -n "${!v:-}" ] && NET_ARGS+=(-e "$v=${!v}")
done
CA="${SSL_CERT_FILE:-}"
[ -n "$CA" ] && [ -f "$CA" ] && NET_ARGS+=(-v "$CA:/etc/harness-ca.crt:ro" -e SSL_CERT_FILE=/etc/harness-ca.crt)

INI=(-d error_reporting="$ERROR_REPORTING" -d display_errors=On -d display_startup_errors=On
     -d log_errors=On -d error_log=/app/docs/php84-spike/harness/out/php.log)
php_run() { docker run --rm "${NET_ARGS[@]}" -v "$REPO:/app" -w /app "$PHP_IMAGE" "$@"; }

# --- 1. image -------------------------------------------------------------
if [ "${SKIP_BUILD:-0}" != 1 ]; then
  log "build $PHP_IMAGE from $REPO/Dockerfile"
  BUILD_ARGS=()
  [ -n "${HTTPS_PROXY:-}" ] && BUILD_ARGS+=(--build-arg "HTTPS_PROXY=$HTTPS_PROXY" --build-arg "https_proxy=$HTTPS_PROXY")
  [ -n "$CA" ] && [ -f "$CA" ] && cp "$CA" "$REPO/docker/extra-ca/harness-proxy-ca.crt"
  docker build --network host "${BUILD_ARGS[@]}" -t "$PHP_IMAGE" "$REPO" > "$OUT/build.log" 2>&1 \
    || { tail -30 "$OUT/build.log"; echo "image build failed"; exit 1; }
fi
log "runtime"
php_run php -v | tee "$OUT/php-v.txt"
if php_run php -r "exit(version_compare(PHP_VERSION, '$MIN_PHP', '>=') ? 0 : 1);"; then
  ok "runtime policy: PHP_VERSION >= $MIN_PHP"
else
  bad "runtime policy: PHP_VERSION < $MIN_PHP (PHP2Shell CVE-2026-109618/109619 unfixed)"
fi
php_run php -m | grep -qx pdo_mysql && ok "pdo_mysql loaded" || bad "pdo_mysql missing"

# --- 2. dependencies --------------------------------------------------------
if [ "${SKIP_COMPOSER:-0}" != 1 ]; then
  log "composer install"
  if php_run composer install --no-interaction --no-progress > "$OUT/composer.log" 2>&1; then
    ok "composer install"
  else
    tail -40 "$OUT/composer.log"; bad "composer install"; exit 1
  fi
fi

# --- 3. database ------------------------------------------------------------
log "MariaDB ($DB_IMAGE on :$DB_PORT)"
docker rm -f "$DB_CT" >/dev/null 2>&1 || true
docker run -d --name "$DB_CT" --network host \
  -e MARIADB_ROOT_PASSWORD=root -e MARIADB_DATABASE=morgue \
  -e MARIADB_USER=morgue -e MARIADB_PASSWORD=morgue_password \
  "$DB_IMAGE" --port="$DB_PORT" --bind-address=127.0.0.1 >/dev/null
for i in $(seq 1 60); do
  docker exec "$DB_CT" mysql -umorgue -pmorgue_password -h127.0.0.1 -P"$DB_PORT" morgue -e 'select 1' >/dev/null 2>&1 && break
  sleep 1
done
# Load order matters: anniversary.sql is a VIEW over postmortems, so it must come
# after postmortems.sql (docker-entrypoint-initdb.d's alphabetical order breaks it).
# schemas/migrations/ are upgrades for old installs and are skipped on a fresh DB.
SCHEMAS=(postmortems.sql)
for f in "$REPO"/schemas/*.sql; do
  b=$(basename "$f"); [ "$b" = postmortems.sql ] || [ "$b" = anniversary.sql ] || SCHEMAS+=("$b")
done
SCHEMAS+=(anniversary.sql)
for s in "${SCHEMAS[@]}"; do
  if docker exec -i "$DB_CT" mysql -umorgue -pmorgue_password -h127.0.0.1 -P"$DB_PORT" morgue \
       < "$REPO/schemas/$s" 2>>"$OUT/schema.log"; then ok "schema $s"; else bad "schema $s"; fi
done

# --- 4. config --------------------------------------------------------------
docker run --rm -e DB_PORT="$DB_PORT" -v "$REPO:/app" -w /app "$PHP_IMAGE" php -r '
  $c = json_decode(file_get_contents("config/example.json"), true);
  $c["environment"] = "development";
  $c["database"]["mysqlhost"] = "127.0.0.1";
  $c["database"]["mysqlport"] = (int) getenv("DB_PORT");
  file_put_contents("config/development.json", json_encode($c, JSON_PRETTY_PRINT|JSON_UNESCAPED_SLASHES)."\n");
'
[ -s "$REPO/config/development.json" ] && ok "config/development.json generated" || bad "config generation"

# --- 5. dev server (README recipe) ------------------------------------------
log "dev server on :$APP_PORT (error_reporting=$ERROR_REPORTING)"
docker rm -f "$APP_CT" >/dev/null 2>&1 || true
: > "$OUT/php.log"
docker run -d --name "$APP_CT" --network host -v "$REPO:/app" -w /app/htdocs \
  -e MORGUE_ENVIRONMENT=development "$PHP_IMAGE" \
  php "${INI[@]}" -d include_path=".:/app:/app/features" -S "127.0.0.1:$APP_PORT" >/dev/null
for i in $(seq 1 30); do curl -s -o /dev/null "$BASE/ping" && break; sleep 0.5; done

# --- 6. smoke ---------------------------------------------------------------
log "smoke"
code=$(curl -s -o "$OUT/ping.body" -w '%{http_code}' "$BASE/ping")
grep -q '"status":"ok"' "$OUT/ping.body" && [ "$code" = 200 ] && ok "GET /ping -> 200 {\"status\":\"ok\"}" \
  || bad "GET /ping -> $code $(head -c 300 "$OUT/ping.body")"

code=$(curl -s -o "$OUT/index.body" -w '%{http_code}' "$BASE/")
[ "$code" = 200 ] && ok "GET / -> 200" || bad "GET / -> $code"

TITLE="harness-smoke-$(date +%s)"
hdrs=$(curl -s -o "$OUT/post.body" -D - "$BASE/events" \
  --data-urlencode "title=$TITLE" \
  -d start_date=10/27/2026 -d start_time=10:00 \
  -d end_date=10/27/2026 -d end_time=11:00 \
  -d detect_date=10/27/2026 -d detect_time=10:05 \
  -d timezone=UTC -d severity=2 \
  -d problem_type=Software -d impact_type=Users -d incident_cause=Change \
  -d subsystem=web -d owner_team=sre)
echo "$hdrs" > "$OUT/post.headers"
loc=$(echo "$hdrs" | tr -d '\r' | awk 'tolower($1)=="location:"{print $2}')
id=${loc##*/events/}
if [[ "$id" =~ ^[0-9]+$ ]]; then ok "POST /events -> redirect $loc"; else bad "POST /events -> no /events/<id> redirect ($(head -1 <<<"$hdrs"))"; fi

if [[ "$id" =~ ^[0-9]+$ ]]; then
  code=$(curl -s -o "$OUT/event.body" -w '%{http_code}' "$BASE/events/$id")
  [ "$code" = 200 ] && grep -q "$TITLE" "$OUT/event.body" && ok "GET /events/$id -> 200, shows title" \
    || bad "GET /events/$id -> $code, title present: $(grep -c "$TITLE" "$OUT/event.body")"
  rows=$(docker exec "$DB_CT" mysql -N -umorgue -pmorgue_password -h127.0.0.1 -P"$DB_PORT" morgue \
         -e "select count(*) from postmortems where title='$TITLE'" 2>/dev/null)
  [ "$rows" = 1 ] && ok "row persisted in postmortems" || bad "postmortems row count=$rows"
fi

# Rendered pages must not carry PHP error text either (display_errors=On).
if grep -lE '(Fatal error|Warning|Notice|Deprecated|Parse error)</b>:|Uncaught ' "$OUT"/*.body >/dev/null 2>&1; then
  bad "PHP error text in responses: $(grep -lE '(Fatal error|Warning|Notice|Deprecated|Parse error)</b>:|Uncaught ' "$OUT"/*.body | xargs -n1 basename | tr '\n' ' ')"
else ok "no PHP error text in responses"; fi

sleep 0.5
if grep -E 'PHP (Fatal|Parse|Warning|Notice|Deprecated|Recoverable)|Uncaught' "$OUT/php.log" >/dev/null; then
  bad "PHP log has errors ($(grep -cE 'PHP ' "$OUT/php.log") lines):"
  grep -E 'PHP ' "$OUT/php.log" | sed 's/^\[[^]]*\] //' | sort | uniq -c | sort -rn | head -20
else ok "PHP log clean (fatals/warnings/notices/deprecations)"; fi

# --- 7. unit tests -----------------------------------------------------------
log "phpunit (filter: $PHPUNIT_FILTER)"
if php_run php -d error_reporting="$ERROR_REPORTING" vendor/bin/phpunit --include-path=phplib \
     --filter "$PHPUNIT_FILTER" tests/unit/ > "$OUT/phpunit.log" 2>&1; then
  ok "phpunit: $(grep -E '^(OK|Tests:)' "$OUT/phpunit.log" | tail -1)"
else
  tail -40 "$OUT/phpunit.log"; bad "phpunit"
fi

log "result"
if [ "$FAILS" = 0 ]; then echo "HARNESS GREEN"; exit 0; else echo "HARNESS RED ($FAILS failures)"; exit 1; fi
