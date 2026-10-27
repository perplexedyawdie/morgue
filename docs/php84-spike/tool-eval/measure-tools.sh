#!/usr/bin/env bash
# Measure what Rector and PHPStan would have caught on the pre-fix tree, versus the
# hand-made fixes (ground truth = JOURNAL 5.2-5.18). All analysis containers run with
# --network none against a read-only copy; nothing in the working tree is modified.
#
#   docs/php84-spike/tool-eval/measure-tools.sh [PREFIX_COMMIT] [WORKDIR]
#
# Needs: docker, git, python3, the morgue-php:local image (harness/run.sh builds it),
# and an installed vendor/ in the repo (same composer.lock as PREFIX_COMMIT).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; REPO="$(cd "$HERE/../../.." && pwd)"
PREFIX="${1:-2314b75}"; W="${2:-$(mktemp -d)}"; IMG="${PHP_IMAGE:-morgue-php:local}"
PHPSTAN_V=2.3.2; DEPR_V=2.0.5; RECTOR_V=2.8.1
mkdir -p "$W/tools" "$W/cfg" "$W/out"
echo "workdir: $W"

# 1. Tools: shallow git clones of the public distribution repos (works where Packagist dist
#    downloads are blocked), wired together as an offline Composer project.
clone() { [ -d "$W/tools/$3" ] || GIT_LFS_SKIP_SMUDGE=1 git -c core.hooksPath=/dev/null -c advice.detachedHead=false clone -q --depth 1 --branch "$2" "https://github.com/$1" "$W/tools/$3"; }
clone phpstan/phpstan "$PHPSTAN_V" phpstan
clone phpstan/phpstan-deprecation-rules "$DEPR_V" deprecation-rules
clone rectorphp/rector "$RECTOR_V" rector
mkdir -p "$W/tools/project"
cat > "$W/tools/project/composer.json" <<JSON
{ "require": {"rector/rector": "$RECTOR_V", "phpstan/phpstan": "$PHPSTAN_V", "phpstan/phpstan-deprecation-rules": "$DEPR_V"},
  "repositories": [
    {"type": "path", "url": "/tools/rector", "options": {"symlink": false, "versions": {"rector/rector": "$RECTOR_V"}}},
    {"type": "path", "url": "/tools/phpstan", "options": {"symlink": false, "versions": {"phpstan/phpstan": "$PHPSTAN_V"}}},
    {"type": "path", "url": "/tools/deprecation-rules", "options": {"symlink": false, "versions": {"phpstan/phpstan-deprecation-rules": "$DEPR_V"}}},
    {"packagist.org": false}] }
JSON
docker run --rm --network none -v "$W/tools:/tools" -w /tools/project "$IMG" composer install -q --no-interaction

# 2. Target: the pre-fix tree + the repo's vendor/ (hardlinked when possible).
rm -rf "$W/prefix"; mkdir -p "$W/prefix"
git -C "$REPO" archive "$PREFIX" | tar -x -C "$W/prefix"
git -C "$REPO" diff --quiet "$PREFIX" HEAD -- composer.json composer.lock \
  || { echo "composer.json/lock differ between $PREFIX and HEAD; install vendor for $PREFIX first"; exit 1; }
cp -al "$REPO/vendor" "$W/prefix/vendor" 2>/dev/null || cp -a "$REPO/vendor" "$W/prefix/vendor"

RUN=(docker run --rm --network none -v "$W/tools:/tools:ro" -v "$W/cfg:/cfg:ro" -w /target)
PATHS="['/target/htdocs', '/target/phplib', '/target/features', '/target/views', '/target/tests']"

# 3. Rector dry runs: A = PHP 8.4 level sets; B = A + Composer-based PHPUnit sets.
rector_cfg() { cat > "$W/cfg/$1.php" <<PHP
<?php
use Rector\Config\RectorConfig;
return RectorConfig::configure()->withPaths($PATHS)
    ->withAutoloadPaths(['/target/vendor/autoload.php'])->withCache('/tmp/rector-cache')
    ->withPhpSets(php84: true)$2;
PHP
}
rector_cfg rector-php84 ""
rector_cfg rector-php84-phpunit "->withComposerBased(phpunit: true)"
# D = only the PHP rules that matched a ground-truth defect, + the PHPUnit sets (small upgrade diff)
cat > "$W/cfg/rector-targeted.php" <<PHP
<?php
use Rector\Config\RectorConfig;
return RectorConfig::configure()->withPaths($PATHS)
    ->withAutoloadPaths(['/target/vendor/autoload.php'])->withCache('/tmp/rector-cache-d')
    ->withRules([
        \Rector\CodingStyle\Rector\FuncCall\ConsistentImplodeRector::class,
        \Rector\Php84\Rector\Param\ExplicitNullableParamTypeRector::class,
        \Rector\CodeQuality\Rector\ClassMethod\OptionalParametersAfterRequiredRector::class,
        \Rector\Php82\Rector\Encapsed\VariableInStringInterpolationFixerRector::class,
        \Rector\Php71\Rector\FuncCall\RemoveExtraParametersRector::class,
    ])
    ->withComposerBased(phpunit: true);
PHP
for c in rector-php84 rector-php84-phpunit rector-targeted; do
  "${RUN[@]}" -v "$W/prefix:/target:ro" "$IMG" php -d memory_limit=2G /tools/project/vendor/bin/rector process \
    --dry-run --no-progress-bar --config "/cfg/$c.php" --output-format json > "$W/out/$c.json" || true
done

# 4. PHPStan levels 0-10, PHP 8.4 semantics, deprecation rules.
for L in $(seq 0 10); do
  cat > "$W/cfg/phpstan-l$L.neon" <<NEON
includes:
    - /tools/project/vendor/phpstan/phpstan-deprecation-rules/rules.neon
parameters:
    level: $L
    phpVersion: 80400
    tmpDir: /tmp/phpstan-l$L
    paths: [/target/htdocs, /target/phplib, /target/features, /target/views, /target/tests]
    bootstrapFiles: [/target/vendor/autoload.php]
NEON
  "${RUN[@]}" -v "$W/prefix:/target:ro" "$IMG" php -d memory_limit=2G /tools/project/vendor/bin/phpstan analyse \
    --no-progress -c "/cfg/phpstan-l$L.neon" --error-format json > "$W/out/phpstan-l$L.json" 2>/dev/null || true
done

# 5. Apply Rector B (full sets) and D (targeted) to copies; check which defects survive.
apply() { rm -rf "$W/$1"; mkdir -p "$W/$1"
  (cd "$W/prefix" && tar --exclude=./vendor -cf - . | tar -xf - -C "$W/$1")
  cp -al "$W/prefix/vendor" "$W/$1/vendor" 2>/dev/null || cp -a "$W/prefix/vendor" "$W/$1/vendor"
  "${RUN[@]}" -v "$W/$1:/target" "$IMG" php -d memory_limit=2G /tools/project/vendor/bin/rector process \
    --no-progress-bar --clear-cache --config "/cfg/$2.php" > /dev/null; }
apply rectored rector-php84-phpunit
apply rectored-targeted rector-targeted
for c in rector-php84 rector-php84-phpunit rector-targeted; do
  python3 -I -c "import json,sys; print(sys.argv[1], json.load(open(sys.argv[2]))['totals'])" "$c" "$W/out/$c.json"
done

python3 -I "$HERE/score.py" "$W/out"
echo
for t in prefix rectored rectored-targeted; do echo "defects open in $t: $(python3 -I "$HERE/defect_check.py" "$W/$t")"; done
echo "defects open in HEAD: $(python3 -I "$HERE/defect_check.py" "$REPO")"
