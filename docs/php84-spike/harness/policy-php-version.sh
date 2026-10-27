#!/usr/bin/env bash
# Runtime policy: the PHP that actually runs in IMAGE must be >= MIN (default 8.4.27, the first
# 8.4 release fixing PHP2Shell CVE-2026-109618/109619). Asks the interpreter itself, because
# image scanners that read OS package databases cannot see a PHP compiled from source.
#   docs/php84-spike/harness/policy-php-version.sh [IMAGE] [MIN]
set -euo pipefail
IMAGE="${1:-morgue-php:local}"; MIN="${2:-8.4.27}"
v=$(docker run --rm "$IMAGE" php -r 'echo PHP_VERSION;')
if docker run --rm "$IMAGE" php -r "exit(version_compare(PHP_VERSION, '$MIN', '>=') ? 0 : 1);"; then
  echo "PASS $IMAGE runs PHP $v (>= $MIN)"
else
  echo "FAIL $IMAGE runs PHP $v (< $MIN): PHP2Shell CVE-2026-109618/109619 not fixed"; exit 1
fi
