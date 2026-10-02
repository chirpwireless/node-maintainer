#!/bin/bash
# Tests update_graphql_stack() from node-update.sh against a fake `docker compose`.
# Usage: tests/graphql_update_test.sh
# shellcheck disable=SC2034  # GRAPHQL_* and DRY_RUN are read by the sourced function
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${ROOT}/tests/fake-bin:${PATH}"

log() { echo "    [$1] ${*:2}" >> "${FAKE_STATE}/log"; }
# shellcheck source=/dev/null
source <(sed -n '/^update_graphql_stack() {/,/^}/p' "${ROOT}/node-update.sh")
# shellcheck source=/dev/null
source <(sed -n '/^graphql_[a-z_]*() {/,/^}/p' "${ROOT}/node-update.sh")

failures=0
check() {
    local name="$1" expected="$2" actual="$3"
    if [[ "${expected}" == "${actual}" ]]; then
        echo "  ok   ${name}"
    else
        echo "  FAIL ${name}: expected '${expected}', got '${actual}'"
        failures=$((failures + 1))
    fi
}

# setup <.env version> <running version> <published versions...>
setup() {
    FAKE_STATE="$(mktemp -d)"
    export FAKE_STATE
    printf 'postgres\nindexer-unpruned\nindexer-events\ngraphql\n' > "${FAKE_STATE}/services"
    echo "SUI_VERSION=$1" > "${FAKE_STATE}/.env"
    : > "${FAKE_STATE}/docker-compose.yml"
    : > "${FAKE_STATE}/calls"
    {
        echo "postgres postgres:16-alpine"
        echo "indexer-unpruned mysten/sui-indexer-alt:$2"
        echo "indexer-events mysten/sui-indexer-alt:$2"
        echo "graphql mysten/sui-indexer-alt-graphql:$2"
    } > "${FAKE_STATE}/running"
    shift 2
    printf '%s\n' "$@" > "${FAKE_STATE}/available"
    printf 'mysten/sui-indexer-alt:%s\nmysten/sui-indexer-alt-graphql:%s\n' "$1" "$1" > "${FAKE_STATE}/pulled"
    GRAPHQL_ENABLED=true
    GRAPHQL_DIR="${FAKE_STATE}"
    GRAPHQL_ENV_FILE="${FAKE_STATE}/.env"
    GRAPHQL_VERSION_VAR=SUI_VERSION
    DRY_RUN=false
    unset FAKE_UP_FAILS FAKE_CONFIG_FAILS
}
run() { update_graphql_stack mainnet "$1" > /dev/null 2>&1; echo $?; }
env_version() { sed -n 's/^SUI_VERSION=//p' "${FAKE_STATE}/.env"; }
running_versions() { awk '$1 != "postgres" {sub(/.*:/, "", $2); print $2}' "${FAKE_STATE}/running" | sort -u | tr '\n' ' ' | sed 's/ $//'; }

echo "images are not published yet when the node is updated"
setup mainnet-v1.79.1 mainnet-v1.79.1 mainnet-v1.79.1
check "update reports failure" 1 "$(run 1.80.1)"
check ".env keeps the running version" mainnet-v1.79.1 "$(env_version)"
check "old containers keep running" mainnet-v1.79.1 "$(running_versions)"
echo mainnet-v1.80.1 >> "${FAKE_STATE}/available"
check "next run retries and updates" 0 "$(run 1.80.1)"
check ".env moves to the new version" mainnet-v1.80.1 "$(env_version)"
check "containers run the new version" mainnet-v1.80.1 "$(running_versions)"

echo ".env already names the new version but containers still run the old one"
setup mainnet-v1.80.1 mainnet-v1.79.1 mainnet-v1.79.1 mainnet-v1.80.1
check "stack is not reported as in sync, update runs" 0 "$(run 1.80.1)"
check "containers run the new version" mainnet-v1.80.1 "$(running_versions)"

echo "one service is down while the others run the target version"
setup mainnet-v1.80.1 mainnet-v1.80.1 mainnet-v1.80.1
grep -v '^indexer-events ' "${FAKE_STATE}/running" > "${FAKE_STATE}/r" && mv "${FAKE_STATE}/r" "${FAKE_STATE}/running"
check "stack is not reported as in sync, update runs" 0 "$(run 1.80.1)"
check "the missing service is started" 1 "$(grep -c '^indexer-events mysten/sui-indexer-alt:mainnet-v1.80.1$' "${FAKE_STATE}/running")"

echo "stack already runs the target version"
setup mainnet-v1.80.1 mainnet-v1.80.1 mainnet-v1.80.1
check "reports in sync" 2 "$(run 1.80.1)"
check "nothing is pulled or restarted" 0 "$(grep -cE '^compose -f [^ ]+ (pull|up)' "${FAKE_STATE}/calls")"

echo "containers fail to start after a successful pull"
setup mainnet-v1.79.1 mainnet-v1.79.1 mainnet-v1.79.1 mainnet-v1.80.1
export FAKE_UP_FAILS=1
check "update reports failure" 1 "$(run 1.80.1)"
unset FAKE_UP_FAILS
check "next run retries and updates" 0 "$(run 1.80.1)"
check "containers run the new version" mainnet-v1.80.1 "$(running_versions)"

echo "dry run on an out-of-sync stack"
setup mainnet-v1.79.1 mainnet-v1.79.1 mainnet-v1.79.1 mainnet-v1.80.1
DRY_RUN=true
check "dry run reports success" 0 "$(run 1.80.1)"
check ".env is untouched" mainnet-v1.79.1 "$(env_version)"
check "nothing is pulled or restarted" 0 "$(grep -cE '^compose -f [^ ]+ (pull|up)' "${FAKE_STATE}/calls")"

echo "compose file cannot be read"
setup mainnet-v1.79.1 mainnet-v1.79.1 mainnet-v1.79.1 mainnet-v1.80.1
export FAKE_CONFIG_FAILS=1
check "update reports failure instead of in sync" 1 "$(run 1.80.1)"
unset FAKE_CONFIG_FAILS
check ".env is untouched" mainnet-v1.79.1 "$(env_version)"

if [[ ${failures} -gt 0 ]]; then
    echo "${failures} check(s) failed"
    exit 1
fi
echo "all checks passed"
