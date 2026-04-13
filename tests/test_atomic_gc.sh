#!/usr/bin/env bash
# tests/test_atomic_gc.sh — Tests for bin/atomic-gc script
# Run: bash tests/test_atomic_gc.sh

source "$(dirname "${BASH_SOURCE[0]}")/test_harness.sh"

SCRIPT="${PROJECT_ROOT}/bin/atomic-gc"

# Mock verify-lib to point to the actual common.sh in the project tree
make_mock verify-lib "echo '${PROJECT_ROOT}/lib/atomic/common.sh'; exit 0"

# ── Help & version (real script) ──────────────────────────

section "Help & version (real script)"

run_cmd bash "$SCRIPT" --help
assert_eq "help → exit 0" "0" "$_rc"
assert_contains "help shows Usage" "Usage" "$_out"
assert_contains "help shows list" "list" "$_out"
assert_contains "help shows rm" "rm" "$_out"
assert_contains "help shows --dry-run" "dry-run" "$_out"
assert_contains "help shows --yes" "--yes" "$_out"
assert_contains "help shows GEN_ID" "GEN_ID" "$_out"

run_cmd bash "$SCRIPT" -h
assert_eq "-h → exit 0" "0" "$_rc"

run_cmd bash "$SCRIPT" -V
assert_eq "-V → exit 0" "0" "$_rc"
assert_contains "version output" "atomic-gc v" "$_out"

# ── Unknown option handling ───────────────────────────────

section "Unknown option handling"

run_cmd bash "$SCRIPT" --bogus-flag
assert_eq "unknown option → rc 1" "1" "$_rc"
assert_contains "unknown option error" "Unknown option" "$_out"

# ── Patched script for behavioral tests ───────────────────

section "Patched script: setup"

# Create a patched copy that:
# - Skips EUID check
# - Skips validate_config
# - Replaces real functions with mocks (inserted after common.sh sourcing)
_TEST_SCRIPT="${TESTDIR}/atomic-gc-test"

# Create fake ESP and BTRFS_MOUNT so rm validation passes
_FAKE_ESP="${TESTDIR}/fake_esp"
_FAKE_BTRFS="${TESTDIR}/fake_btrfs"
mkdir -p "${_FAKE_ESP}/EFI/Linux" "${_FAKE_BTRFS}"
# Create fake UKI files and subvols for rm validation
touch "${_FAKE_ESP}/EFI/Linux/arch-20250604-100000.efi"
mkdir -p "${_FAKE_BTRFS}/root-20250604-100000"
touch "${_FAKE_ESP}/EFI/Linux/arch-20250603-080000.efi"
mkdir -p "${_FAKE_BTRFS}/root-20250603-080000"
touch "${_FAKE_ESP}/EFI/Linux/arch-20250615-120000.efi"
mkdir -p "${_FAKE_BTRFS}/root-20250615-120000"
touch "${_FAKE_ESP}/EFI/Linux/arch-20250615-120000-kde.efi"
mkdir -p "${_FAKE_BTRFS}/root-20250615-120000-kde"

# Build the patch content to inject after common.sh is sourced
cat > "${TESTDIR}/gc-mocks.txt" << PATCH

# === Test mocks (injected) ===
# Override paths for test environment
ESP="${_FAKE_ESP}"
BTRFS_MOUNT="${_FAKE_BTRFS}"

acquire_lock()        { echo "ACQUIRE_LOCK"; }
ensure_btrfs_mounted(){ echo "ENSURE_BTRFS"; return 0; }
get_current_subvol()  { echo "root-20250605-120000"; }
list_generations() {
    echo "20250605-120000"
    echo "20250604-100000"
    echo "20250603-080000"
}
delete_generation() {
    local gen_id="\$1" dry_run="\${2:-0}" current_subvol="\${3:-root-20250605-120000}"
    echo "DELETE_GEN \$gen_id dry=\$dry_run"
    return 0
}
warn_orphan_homes() {
    echo "WARN_ORPHANS \$*"
}
garbage_collect() {
    echo "GC_CALLED keep=\$1 dry=\$2"
    return 0
}

PATCH

# Patch: skip EUID/validate_config, inject mocks after common.sh
sed \
    -e 's/\(\[\[ \$EUID -eq 0 \]\]\)/# \1/' \
    -e '/^validate_config || exit 1$/s/^/# /' \
    -e '/^_src "\${LIBDIR}\/common.sh"$/r '"${TESTDIR}/gc-mocks.txt"'' \
    "$SCRIPT" > "$_TEST_SCRIPT"

chmod +x "$_TEST_SCRIPT"

_run_gc() {
    run_cmd bash "$_TEST_SCRIPT" "$@"
}

# ── list command ──────────────────────────────────────────

section "list command"

_run_gc list
assert_eq "list → exit 0" "0" "$_rc"
assert_contains "list shows gen 1" "20250605-120000" "$_out"
assert_contains "list shows gen 2" "20250604-100000" "$_out"
assert_contains "list shows gen 3" "20250603-080000" "$_out"
assert_contains "list marks current" "current" "$_out"

# ── rm command: argument validation ──────────────────────

section "rm command: argument validation"

_run_gc rm
assert_eq "rm without args → rc 1" "1" "$_rc"
assert_contains "rm error message" "Specify generation" "$_out"

_run_gc rm --yes "20250604-100000"
assert_eq "single delete → rc 0" "0" "$_rc"
assert_contains "delete called" "DELETE_GEN" "$_out"
assert_contains "lock acquired" "ACQUIRE_LOCK" "$_out"

_run_gc rm --yes "20250604-100000" "20250603-080000"
assert_eq "multi delete → rc 0" "0" "$_rc"

# ── rm command: GEN_ID format validation ─────────────────

section "rm command: GEN_ID format validation"

_run_gc rm --yes "invalid"
assert_eq "invalid GEN_ID → rc 1" "1" "$_rc"

_run_gc rm --yes ""
assert_eq "empty GEN_ID → rc 1" "1" "$_rc"

_run_gc rm --yes "20250615"
assert_eq "partial timestamp → rc 1" "1" "$_rc"

_run_gc rm --yes "20250615-120000"
assert_eq "valid plain GEN_ID → rc 0" "0" "$_rc"

_run_gc rm --yes "20250615-120000-kde"
assert_eq "valid tagged GEN_ID → rc 0" "0" "$_rc"

# ── rm command: dry-run mode ─────────────────────────────

section "rm command: dry-run mode"

_run_gc rm -n "20250604-100000"
assert_eq "dry-run rm → rc 0" "0" "$_rc"
assert_contains "dry-run echoes delete" "DELETE_GEN" "$_out"
assert_contains "dry-run echoes dry flag" "dry=1" "$_out"
assert_contains "dry-run warns orphans" "WARN_ORPHANS" "$_out"

# ── gc command: count validation ──────────────────────────

section "gc command: count validation"

_run_gc 2
assert_eq "gc with count 2 → rc 0" "0" "$_rc"
assert_contains "gc called" "GC_CALLED" "$_out"
assert_contains "gc keep value" "keep=2" "$_out"

_run_gc 0
assert_eq "gc with count 0 → rc 1" "1" "$_rc"
assert_contains "gc count 0 error" "Invalid count" "$_out"

_run_gc -1
assert_eq "gc with negative count → rc 1" "1" "$_rc"

_run_gc abc
assert_eq "gc with text count → rc 1" "1" "$_rc"

_run_gc
assert_eq "gc default count → rc 0" "0" "$_rc"

# ── gc command: dry-run ──────────────────────────────────

section "gc command: dry-run"

_run_gc -n
assert_eq "gc dry-run → rc 0" "0" "$_rc"
assert_contains "gc dry-run flag" "dry=1" "$_out"

# ── Cleanup trap: verify in real script ───────────────────

section "Cleanup trap: verify in real script"

_script_content=$(cat "$SCRIPT")

assert_contains "has cleanup_gc function" "cleanup_gc" "$_script_content"
assert_contains "trap references cleanup" "trap cleanup_gc EXIT" "$_script_content"
assert_contains "cleanup unmounts BTRFS" "BTRFS_MOUNT" "$_script_content"
assert_contains "cleanup closes lock" "LOCK_FD" "$_script_content"
grep -q 'umount.*BTRFS_MOUNT' "$SCRIPT" && ok "cleanup calls umount" || fail "cleanup calls umount"

summary
