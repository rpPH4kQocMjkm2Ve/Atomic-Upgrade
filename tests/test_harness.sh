#!/usr/bin/env bash
# tests/test_harness.sh
#
# Shared test harness for common.sh unit tests.
# Sourced by individual test files — NOT run directly.
#
# Provides:
#   - Assertion functions (ok, fail, assert_eq, assert_match, assert_contains, etc.)
#   - run_cmd / assert_rc helpers
#   - Temporary TESTDIR with EXIT cleanup
#   - MOCK_BIN on PATH with default mocks
#   - make_mock / make_mock_in utilities
#   - Sources common.sh with _ATOMIC_NO_INIT=1

set -uo pipefail

PASS=0
FAIL=0
TESTS=0

# ── Test helpers ─────────────────────────────────────────────

ok() {
    PASS=$((PASS + 1))
    TESTS=$((TESTS + 1))
    echo "  ✓ $1"
}

fail() {
    FAIL=$((FAIL + 1))
    TESTS=$((TESTS + 1))
    echo "  ✗ $1"
}

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        ok "$desc"
    else
        fail "$desc (expected='$expected', got='$actual')"
    fi
}

assert_match() {
    local desc="$1" pattern="$2" actual="$3"
    if [[ "$actual" =~ $pattern ]]; then
        ok "$desc"
    else
        fail "$desc (pattern='$pattern' not found in '$actual')"
    fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        ok "$desc"
    else
        fail "$desc (needle='$needle' not in output)"
    fi
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        ok "$desc"
    else
        fail "$desc (needle='$needle' unexpectedly found)"
    fi
}

# Run command in subshell, capture rc + combined stdout/stderr.
# Sets globals: _rc, _out
# Use when side effects in parent shell are NOT needed.
run_cmd() {
    _rc=0
    _out=$("$@" 2>&1) || _rc=$?
}

# Check only the return code (suppress output).
# Use for simple pass/fail where output doesn't matter.
assert_rc() {
    local desc="$1" expected="$2"
    shift 2
    local rc=0
    "$@" >/dev/null 2>&1 || rc=$?
    assert_eq "$desc" "$expected" "$rc"
}

section() {
    echo ""
    echo "── $1 ──"
}

# ── Setup test environment ───────────────────────────────────

TESTDIR=$(mktemp -d)
trap 'rm -rf "$TESTDIR"' EXIT

# Create mock bin directory — prepended to PATH so mocks override real cmds
MOCK_BIN="${TESTDIR}/mock_bin"
mkdir -p "$MOCK_BIN"

# Save original PATH for later restoration
ORIG_PATH="$PATH"

# Write a mock script into MOCK_BIN.
# Args: name [body]
# The body receives all original arguments in $@ / $* / "$1" etc.
make_mock() {
    local name="$1"; shift
    local body="${*:-exit 0}"
    cat > "${MOCK_BIN}/${name}" <<ENDSCRIPT
#!/bin/bash
${body}
ENDSCRIPT
    chmod +x "${MOCK_BIN}/${name}"
}

# Write a mock script into an arbitrary directory.
# Used by check_dependencies test to create an isolated PATH.
make_mock_in() {
    local dir="$1" name="$2"; shift 2
    local body="${*:-exit 0}"
    mkdir -p "$dir"
    cat > "${dir}/${name}" <<ENDSCRIPT
#!/bin/bash
${body}
ENDSCRIPT
    chmod +x "${dir}/${name}"
}

# ── Prepare environment before sourcing common.sh ────────────

export PATH="${MOCK_BIN}:${PATH}"

# Smart stat mock: intercept ownership checks (stat -c %u),
# proxy everything else to real stat.  A blanket "echo 0" mock
# would break anything internally relying on stat.
REAL_STAT=$(command -v stat 2>/dev/null || echo /usr/bin/stat)
make_mock stat "
if [[ \"\${1:-}\" == \"-c\" && \"\${2:-}\" == \"%u\" ]]; then
    echo \"0\"
else
    exec \"${REAL_STAT}\" \"\$@\"
fi
"

make_mock findmnt    'echo ""'
make_mock mountpoint 'exit 0'
make_mock python3    'echo ""'
make_mock mount      'exit 0'
make_mock btrfs      'exit 0'
make_mock flock      'exit 0'
make_mock df         'echo ""'

# Skip auto-init; tests call load_config explicitly with controlled
# CONFIG_FILE values.  This also avoids reading /etc/atomic.conf on
# CI machines where the file may not exist or may not be root-owned.
_ATOMIC_NO_INIT=1

# Resolve project root relative to the harness file itself
_HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$_HARNESS_DIR/.." && pwd)"

# shellcheck source=../lib/atomic/common.sh
source "${PROJECT_ROOT}/lib/atomic/common.sh"

# ── Summary function ─────────────────────────────────────────

summary() {
    local name="${0##*/}"
    echo ""
    echo "════════════════════════════════════"
    echo " ${name}: ${PASS} passed, ${FAIL} failed (total: ${TESTS})"
    echo "════════════════════════════════════"

    if [[ $FAIL -ne 0 ]]; then
        exit 1
    fi
    exit 0
}
