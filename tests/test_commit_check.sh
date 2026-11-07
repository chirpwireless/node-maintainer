#!/bin/bash
# Tests for the release build-commit verification in node-update.sh.
# Network is stubbed: curl is replaced by a function serving fixture JSON.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

assert_eq() {
    if [[ "$2" == "$3" ]]; then ok "$1"; else fail "$1 (expected '$3', got '$2')"; fi
}

TAG_COMMIT="6a567faf6de1fa2b3c4d5e6f708192a3b4c5d6e7"
OLD_COMMIT_SHORT="0e0ede4cbf48"
NEW_COMMIT_SHORT="6a567faf6de1"
TAG_OBJ_SHA="1111111111111111111111111111111111111111"
DIGEST_HEX="a54b24da3c8fd4b88522f01c8718826ae5637512ee0953469a5759408e1f701b"

# Curl stub state: URL suffix -> "<http code>|<fixture file>"
declare -A ROUTES

curl() {
    local url="" arg
    for arg in "$@"; do
        [[ "${arg}" == https://* ]] && url="${arg}"
    done
    echo "${url}" >> "${WORK}/curl_calls.log"
    local key="${url#https://api.github.com/repos/MystenLabs/sui/}"
    local route="${ROUTES[${key}]:-404|}"
    local code="${route%%|*}" file="${route#*|}"
    if [[ -n "${file}" ]]; then cat "${file}"; fi
    printf '\n%s' "${code}"
}

write() { printf '%s' "$2" > "${WORK}/$1"; echo "${WORK}/$1"; }

setup_routes() {
    ROUTES=()
    : > "${WORK}/curl_calls.log"
    ROUTES["git/ref/tags/mainnet-v1.83.1"]="200|$(write ref_lightweight.json "{\"object\":{\"type\":\"commit\",\"sha\":\"${TAG_COMMIT}\"}}")"
    ROUTES["releases/tags/mainnet-v1.83.1"]="200|$(write release.json "{\"assets\":[{\"name\":\"other.tgz\",\"digest\":\"sha256:$(printf 'b%.0s' {1..64})\"},{\"name\":\"sui-mainnet-v1.83.1-ubuntu-x86_64.tgz\",\"digest\":\"sha256:${DIGEST_HEX}\"}]}")"
}

# Source the script in a subshell with a given node type; remaining args are the test body.
run_in_script() {
    local node_type="$1"; shift
    (
        export NODE_TYPE="${node_type}" NETWORK=mainnet
        # shellcheck disable=SC1091
        source "${ROOT}/node-update.sh" 2>/dev/null
        set +e
        export -f curl 2>/dev/null || true
        "$@"
    )
}

# ----- decide_update -----

t_decide_same_commit() {
    decide_update 1.83.1 1.83.1 "${NEW_COMMIT_SHORT}" "${TAG_COMMIT}"
}
assert_eq "same version + same commit -> no install" "$(run_in_script sui t_decide_same_commit)" "skip-current"

t_decide_diff_commit() {
    decide_update 1.83.1 1.83.1 "${OLD_COMMIT_SHORT}" "${TAG_COMMIT}"
}
assert_eq "same version + different commit -> install" "$(run_in_script sui t_decide_diff_commit)" "install-rebuild"

t_decide_newer() {
    decide_update 1.83.1 1.84.0 "${NEW_COMMIT_SHORT}" "${TAG_COMMIT}"
}
assert_eq "newer version -> install" "$(run_in_script sui t_decide_newer)" "install-newer"

t_decide_installed_newer() {
    decide_update 1.84.0 1.83.1 "${OLD_COMMIT_SHORT}" "${TAG_COMMIT}"
}
assert_eq "installed newer than release -> no install" "$(run_in_script sui t_decide_installed_newer)" "skip-installed-newer"

t_decide_unparsed_installed() {
    decide_update 1.83.1 1.83.1 "" "${TAG_COMMIT}"
}
assert_eq "same version + unparsable installed commit -> old behaviour" "$(run_in_script sui t_decide_unparsed_installed)" "skip-unknown-commit"

t_decide_walrus() {
    decide_update 1.2.3 1.2.3 "${OLD_COMMIT_SHORT}" "${TAG_COMMIT}"
}
assert_eq "walrus (no COMMIT_REGEX) same version -> old behaviour" "$(run_in_script walrus t_decide_walrus)" "skip-unknown-commit"

t_decide_walrus_newer() {
    decide_update 1.2.3 1.3.0 "" ""
}
assert_eq "walrus newer version -> install" "$(run_in_script walrus t_decide_walrus_newer)" "install-newer"

# ----- commit parsing -----

t_parse_sui() { parse_commit_from_version_output "sui-node 1.83.1-6a567faf6de1"; }
assert_eq "parse sui --version commit" "$(run_in_script sui t_parse_sui)" "${NEW_COMMIT_SHORT}"

t_parse_garbage() { parse_commit_from_version_output "something else"; }
assert_eq "parse garbage -> empty" "$(run_in_script sui t_parse_garbage)" ""

t_parse_walrus() { parse_commit_from_version_output "walrus-node 1.2.3-abcdef"; }
assert_eq "walrus parse -> empty (COMMIT_REGEX unset)" "$(run_in_script walrus t_parse_walrus)" ""

# ----- tag resolution -----

t_resolve() { setup_routes; resolve_tag_commit mainnet-v1.83.1; }
assert_eq "lightweight tag resolves to commit" "$(run_in_script sui t_resolve)" "${TAG_COMMIT}"

t_resolve_annotated() {
    setup_routes
    ROUTES["git/ref/tags/mainnet-v1.83.1"]="200|$(write ref_annotated.json "{\"object\":{\"type\":\"tag\",\"sha\":\"${TAG_OBJ_SHA}\"}}")"
    ROUTES["git/tags/${TAG_OBJ_SHA}"]="200|$(write tag_obj.json "{\"object\":{\"type\":\"commit\",\"sha\":\"${TAG_COMMIT}\"}}")"
    resolve_tag_commit mainnet-v1.83.1
}
assert_eq "annotated tag is dereferenced to commit" "$(run_in_script sui t_resolve_annotated)" "${TAG_COMMIT}"

t_resolve_api_failure() {
    setup_routes
    ROUTES["git/ref/tags/mainnet-v1.83.1"]="403|$(write rate.json '{"message":"API rate limit exceeded"}')"
    if out=$(resolve_tag_commit mainnet-v1.83.1); then echo "resolved:${out}"; else echo "failed"; fi
}
assert_eq "API failure -> no commit (no install)" "$(run_in_script sui t_resolve_api_failure)" "failed"

t_resolve_not_commit() {
    setup_routes
    ROUTES["git/ref/tags/mainnet-v1.83.1"]="200|$(write ref_tree.json "{\"object\":{\"type\":\"tree\",\"sha\":\"${TAG_COMMIT}\"}}")"
    if out=$(resolve_tag_commit mainnet-v1.83.1); then echo "resolved:${out}"; else echo "failed"; fi
}
assert_eq "tag pointing at non-commit -> failure" "$(run_in_script sui t_resolve_not_commit)" "failed"

# ----- digest -----

t_digest() { setup_routes; get_release_asset_digest mainnet-v1.83.1 sui-mainnet-v1.83.1-ubuntu-x86_64.tgz; }
assert_eq "digest of matching asset" "$(run_in_script sui t_digest)" "${DIGEST_HEX}"

t_digest_null() {
    setup_routes
    ROUTES["releases/tags/mainnet-v1.83.1"]="200|$(write release_null.json '{"assets":[{"name":"sui-mainnet-v1.83.1-ubuntu-x86_64.tgz","digest":null}]}')"
    get_release_asset_digest mainnet-v1.83.1 sui-mainnet-v1.83.1-ubuntu-x86_64.tgz
}
assert_eq "null digest -> empty, success" "$(run_in_script sui t_digest_null)" ""

t_digest_api_failure() {
    setup_routes
    ROUTES["releases/tags/mainnet-v1.83.1"]="500|"
    if get_release_asset_digest mainnet-v1.83.1 x.tgz >/dev/null; then echo ok; else echo failed; fi
}
assert_eq "release API failure -> failure" "$(run_in_script sui t_digest_api_failure)" "failed"

t_api_call_count() {
    setup_routes
    resolve_tag_commit mainnet-v1.83.1 >/dev/null
    get_release_asset_digest mainnet-v1.83.1 x.tgz >/dev/null
    wc -l < "${WORK}/curl_calls.log" | tr -d " "
}
assert_eq "lightweight tag: 2 API calls" "$(run_in_script sui t_api_call_count)" "2"

# ----- digest verification -----

printf 'archive-bytes' > "${WORK}/a.tgz"
GOOD="$(sha256sum "${WORK}/a.tgz" | awk '{print $1}')"
t_verify_ok() { verify_sha256 "${WORK}/a.tgz" "${GOOD}" && echo ok || echo bad; }
assert_eq "sha256 match accepted" "$(run_in_script sui t_verify_ok)" "ok"
t_verify_bad() { verify_sha256 "${WORK}/a.tgz" "${DIGEST_HEX}" && echo ok || echo bad; }
assert_eq "sha256 mismatch rejected" "$(run_in_script sui t_verify_bad)" "bad"

# ----- download_and_install: digest mismatch aborts, nothing installed -----

t_install_digest_mismatch() {
    setup_routes
    local inst="${WORK}/install" dl="${WORK}/dl"
    mkdir -p "${inst}" "${dl}" "${WORK}/pkg"
    printf '#!/bin/bash\necho "sui-node 1.83.1-%s"\n' "${OLD_COMMIT_SHORT}" > "${inst}/sui-node"
    chmod +x "${inst}/sui-node"
    printf '#!/bin/bash\n' > "${WORK}/pkg/sui-node"; printf '#!/bin/bash\n' > "${WORK}/pkg/sui-tool"
    tar czf "${WORK}/release.tgz" -C "${WORK}/pkg" sui-node sui-tool
    wget() { cp "${WORK}/release.tgz" "$3"; }
    systemctl() { echo "systemctl $*" >> "${WORK}/systemctl.log"; }
    PRIMARY_BIN_PATH="${inst}/sui-node"; SECONDARY_BIN_PATH="${inst}/sui-tool"
    INSTALL_DIR="${inst}"; DOWNLOAD_DIR="${dl}"; DRY_RUN=false
    ( download_and_install mainnet 1.83.1 ubuntu-x86_64 "http://x/y.tgz" "${TAG_COMMIT}" "${DIGEST_HEX}" ) >/dev/null 2>&1
    local rc=$?
    local still_old; still_old=$("${inst}/sui-node")
    echo "rc=${rc} binary=${still_old} systemctl_calls=$([[ -f ${WORK}/systemctl.log ]] && wc -l < "${WORK}/systemctl.log" || echo 0)"
}
assert_eq "digest mismatch -> abort, old binary kept, service untouched" \
    "$(run_in_script sui t_install_digest_mismatch)" "rc=1 binary=sui-node 1.83.1-${OLD_COMMIT_SHORT} systemctl_calls=0"

# ----- download_and_install: rebuild installs into fresh commit-named dir, restores on bad build -----

t_install_rebuild() {
    setup_routes
    local inst="${WORK}/install2" dl="${WORK}/dl2" pkg="${WORK}/pkg2"
    mkdir -p "${inst}" "${dl}/sui-mainnet-v1.83.1-ubuntu-x86_64" "${pkg}"
    printf '#!/bin/bash\necho "sui-node 1.83.1-%s"\n' "${OLD_COMMIT_SHORT}" > "${inst}/sui-node"
    printf '#!/bin/bash\n' > "${inst}/sui-tool"; chmod +x "${inst}/sui-node" "${inst}/sui-tool"
    echo stale > "${dl}/sui-mainnet-v1.83.1-ubuntu-x86_64/stale-file"
    printf '#!/bin/bash\necho "sui-node 1.83.1-%s"\n' "${NEW_COMMIT_SHORT}" > "${pkg}/sui-node"
    printf '#!/bin/bash\n' > "${pkg}/sui-tool"
    tar czf "${WORK}/release2.tgz" -C "${pkg}" sui-node sui-tool
    local digest; digest=$(sha256sum "${WORK}/release2.tgz" | awk '{print $1}')
    wget() { cp "${WORK}/release2.tgz" "$3"; }
    systemctl() { return 0; }
    sleep() { :; }
    PRIMARY_BIN_PATH="${inst}/sui-node"; SECONDARY_BIN_PATH="${inst}/sui-tool"
    INSTALL_DIR="${inst}"; DOWNLOAD_DIR="${dl}"; DRY_RUN=false
    ( download_and_install mainnet 1.83.1 ubuntu-x86_64 "http://x/y.tgz" "${TAG_COMMIT}" "${digest}" ) >/dev/null 2>&1
    local rc=$?
    echo "rc=${rc} binary=$("${inst}/sui-node") fresh_dir=$([[ -d ${dl}/sui-mainnet-v1.83.1-${NEW_COMMIT_SHORT}-ubuntu-x86_64 ]] && echo yes || echo no)"
}
assert_eq "rebuild installs new binary into commit-named dir" \
    "$(run_in_script sui t_install_rebuild)" "rc=0 binary=sui-node 1.83.1-${NEW_COMMIT_SHORT} fresh_dir=yes"

t_install_wrong_build() {
    setup_routes
    local inst="${WORK}/install3" dl="${WORK}/dl3" pkg="${WORK}/pkg3"
    mkdir -p "${inst}" "${dl}" "${pkg}"
    printf '#!/bin/bash\necho "sui-node 1.83.1-%s"\n' "${OLD_COMMIT_SHORT}" > "${inst}/sui-node"
    printf '#!/bin/bash\n' > "${inst}/sui-tool"; chmod +x "${inst}/sui-node" "${inst}/sui-tool"
    printf '#!/bin/bash\necho "sui-node 1.83.1-%s"\n' "${OLD_COMMIT_SHORT}" > "${pkg}/sui-node"
    printf '#!/bin/bash\n' > "${pkg}/sui-tool"
    tar czf "${WORK}/release3.tgz" -C "${pkg}" sui-node sui-tool
    wget() { cp "${WORK}/release3.tgz" "$3"; }
    systemctl() { echo "systemctl $*" >> "${WORK}/systemctl3.log"; }
    sleep() { :; }
    PRIMARY_BIN_PATH="${inst}/sui-node"; SECONDARY_BIN_PATH="${inst}/sui-tool"
    INSTALL_DIR="${inst}"; DOWNLOAD_DIR="${dl}"; DRY_RUN=false
    ( download_and_install mainnet 1.83.1 ubuntu-x86_64 "http://x/y.tgz" "${TAG_COMMIT}" "" ) >/dev/null 2>&1
    local rc=$?
    echo "rc=${rc} stops=$(grep -c stop "${WORK}/systemctl3.log" 2>/dev/null || echo 0)"
}
assert_eq "archive with wrong build commit -> abort before stopping service" \
    "$(run_in_script sui t_install_wrong_build)" "rc=1 stops=0"

echo
echo "Passed: ${PASS}, Failed: ${FAIL}"
[[ ${FAIL} -eq 0 ]]
