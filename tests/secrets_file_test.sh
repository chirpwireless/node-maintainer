#!/bin/bash
# Tests load_secrets_file() from node-update.sh.
# Usage: tests/secrets_file_test.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"

log() { echo "[$1] ${*:2}" >> "${WORK}/log"; }
# shellcheck source=/dev/null
source <(sed -n '/^load_secrets_file() {/,/^}/p' "${ROOT}/node-update.sh")

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
reset() {
    TELEGRAM_BOT_TOKEN=""
    TELEGRAM_CHAT_ID=""
    SECRETS_FILE="${WORK}/secrets.env"
    rm -f "${SECRETS_FILE}" "${WORK}/log" "${WORK}/pwned"
    touch "${WORK}/log"
}

echo "no secrets file"
reset
load_secrets_file
check "token stays empty" "" "${TELEGRAM_BOT_TOKEN}"
check "chat ids stay empty" "" "${TELEGRAM_CHAT_ID}"

echo "file with quoted values, CRLF endings and no trailing newline"
reset
printf 'TELEGRAM_BOT_TOKEN="111:aaa"\r\nTELEGRAM_CHAT_ID=1,-2' > "${SECRETS_FILE}"
chmod 600 "${SECRETS_FILE}"
load_secrets_file
check "token is read" "111:aaa" "${TELEGRAM_BOT_TOKEN}"
check "chat ids are read" "1,-2" "${TELEGRAM_CHAT_ID}"
check "no permission warning for 600" 0 "$(grep -c 'readable by group or others' "${WORK}/log" || true)"

echo "environment values win over the file"
reset
printf 'TELEGRAM_BOT_TOKEN=from-file\nTELEGRAM_CHAT_ID=from-file\n' > "${SECRETS_FILE}"
chmod 600 "${SECRETS_FILE}"
TELEGRAM_BOT_TOKEN="from-env"
load_secrets_file
check "token from the environment is kept" "from-env" "${TELEGRAM_BOT_TOKEN}"
check "chat ids missing in the environment come from the file" "from-file" "${TELEGRAM_CHAT_ID}"

echo "file content is never executed and unknown keys are ignored"
reset
# shellcheck disable=SC2016  # the file must contain a literal command substitution
printf 'TELEGRAM_CHAT_ID=$(touch %s/pwned)\nPATH=/nowhere\n' "${WORK}" > "${SECRETS_FILE}"
chmod 600 "${SECRETS_FILE}"
load_secrets_file
check "command substitution is not run" "no" "$([[ -e "${WORK}/pwned" ]] && echo yes || echo no)"
check "value is taken literally" "\$(touch ${WORK}/pwned)" "${TELEGRAM_CHAT_ID}"
check "PATH is untouched" "yes" "$([[ "${PATH}" != "/nowhere" ]] && echo yes || echo no)"

echo "file readable by others"
reset
printf 'TELEGRAM_BOT_TOKEN=x\n' > "${SECRETS_FILE}"
chmod 644 "${SECRETS_FILE}"
load_secrets_file
check "permission warning is logged" 1 "$(grep -c 'readable by group or others (mode 644)' "${WORK}/log" || true)"
check "token is still read" "x" "${TELEGRAM_BOT_TOKEN}"

echo "export prefix, spaces around =, single quotes and = inside the value"
reset
printf "export TELEGRAM_BOT_TOKEN = 'a:b=c'\n  TELEGRAM_CHAT_ID=  1,-2  \n" > "${SECRETS_FILE}"
chmod 600 "${SECRETS_FILE}"
load_secrets_file
check "token is read without quotes and with its =" "a:b=c" "${TELEGRAM_BOT_TOKEN}"
check "chat ids are trimmed" "1,-2" "${TELEGRAM_CHAT_ID}"

echo "file owned by another user"
reset
printf 'TELEGRAM_BOT_TOKEN=x\n' > "${SECRETS_FILE}"
chmod 600 "${SECRETS_FILE}"
load_secrets_file
if [[ "$(id -u)" == "0" ]]; then
    check "no owner warning for root" 0 "$(grep -c 'not owned by root' "${WORK}/log" || true)"
else
    check "owner warning is logged" 1 "$(grep -c "not owned by root (uid $(id -u))" "${WORK}/log" || true)"
fi

echo "symlink to a world-readable file"
reset
printf 'TELEGRAM_BOT_TOKEN=x\n' > "${WORK}/target.env"
chmod 644 "${WORK}/target.env"
ln -sf "${WORK}/target.env" "${SECRETS_FILE}"
load_secrets_file
check "mode of the target is reported" 1 "$(grep -c 'readable by group or others (mode 644)' "${WORK}/log" || true)"
rm -f "${WORK}/target.env"

echo "token loaded from the file is not passed to child processes"
reset
printf 'TELEGRAM_BOT_TOKEN=from-file\n' > "${SECRETS_FILE}"
chmod 600 "${SECRETS_FILE}"
export TELEGRAM_BOT_TOKEN=""
load_secrets_file
check "the script itself sees the token" "from-file" "${TELEGRAM_BOT_TOKEN}"
check "a child process does not" "unset" "$(bash -c 'echo "${TELEGRAM_BOT_TOKEN:-unset}"')"

if [[ ${failures} -gt 0 ]]; then
    echo "${failures} check(s) failed"
    exit 1
fi
echo "all checks passed"
