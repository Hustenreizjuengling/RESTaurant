#!/usr/bin/env bash
# Developer helper around the local Docker sandbox (see dev/docker).
#
#   scripts/dev.sh validate          validate the APEXlang sources in src/
#   scripts/dev.sh import            validate and import src/ into the sandbox
#   scripts/dev.sh export            write the single-file installer to dist/
#   scripts/dev.sh sql [file]        open SQLcl as the parsing schema (or run a file)
#   scripts/dev.sh test              play the application through, see tests/e2e
set -euo pipefail

CONTAINER="${RESTAURANT_ORDS_CONTAINER:-restaurant-dev-ords-1}"
CONNECT="${RESTAURANT_CONNECT:-restaurant/Restaurant_4U@db:1521/FREEPDB1}"
APP_ID="${RESTAURANT_APP_ID:-14850}"
export MSYS_NO_PATHCONV=1

sqlcl() { docker exec -i "$CONTAINER" sql -S "$@"; }

case "${1:-}" in
  validate)
    out=$(printf 'apex validate -input /repo/src\nexit\n' | sqlcl /nolog 2>&1 || true)
    printf '%s\n' "$out"
    grep -Fq "Validation successful" <<<"$out"
    ;;
  import)
    "$0" validate
    printf 'apex import -input /repo/src\nexit\n' | sqlcl "$CONNECT"
    ;;
  export)
    mkdir -p "$(dirname "$0")/../dist"
    printf 'apex export -applicationid %s -dir /repo/dist -skipexportdate -overwrite-files\nexit\n' "$APP_ID" | sqlcl "$CONNECT"
    mv "$(dirname "$0")/../dist/f${APP_ID}.sql" "$(dirname "$0")/../dist/restaurant.sql"
    ;;
  sql)
    if [ -n "${2:-}" ]; then
      docker exec -i "$CONTAINER" sql -S "$CONNECT" < "$2"
    else
      docker exec -it "$CONTAINER" sql "$CONNECT"
    fi
    ;;
  test)
    shift
    "$(dirname "$0")/../tests/e2e/run.sh" "$@"
    ;;
  *)
    sed -n '2,9p' "$0"; exit 2 ;;
esac
