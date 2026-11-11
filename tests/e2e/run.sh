#!/usr/bin/env bash
# End-to-end walkthrough of RESTaurant against the local sandbox (dev/docker).
#
#   tests/e2e/run.sh            reset the test schemas, install dist/restaurant.sql, run all checks
#   tests/e2e/run.sh --keep     run the checks again without resetting and installing
#
# Needs Node.js. The first run installs Playwright into tests/e2e/node_modules.
set -euo pipefail

cd "$(dirname "$0")/../.."
CONTAINER="${RESTAURANT_ORDS_CONTAINER:-restaurant-dev-ords-1}"
DATABASE="${RESTAURANT_DATABASE:-db:1521/FREEPDB1}"
SYS_PASSWORD="${ORACLE_PASSWORD:-Oracle_4U}"
export MSYS_NO_PATHCONV=1

if [ "${1:-}" != "--keep" ]; then
  echo "== reset the test schemas"
  docker exec -i "$CONTAINER" sql -S "sys/${SYS_PASSWORD}@${DATABASE} as sysdba" @/repo/tests/e2e/setup.sql
  echo "== install the application for both schemas"
  docker exec -w /repo -i "$CONTAINER" sql -S "e2e_rest/Restaurant_4U@${DATABASE}" @install.sql E2E E2E_REST 200 | tail -n 1
  docker exec -w /repo -i "$CONTAINER" sql -S "e2e_rest_b/Restaurant_4U@${DATABASE}" @install.sql E2E E2E_REST_B 201 | tail -n 1
fi

cd tests/e2e
if [ ! -d node_modules/playwright ]; then
  npm install --no-audit --no-fund
  npx playwright install chromium
fi
node walkthrough.mjs "$@"
