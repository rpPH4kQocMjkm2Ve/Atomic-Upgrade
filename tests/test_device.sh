#!/usr/bin/env bash
# tests/test_device.sh — Subvolume/device detection, btrfs mount, validation
# Run: bash tests/test_device.sh

source "$(dirname "${BASH_SOURCE[0]}")/test_harness.sh"


# ── get_current_subvol / get_current_subvol_raw ─────────────

section "get_current_subvol"

# Typical btrfs mount options with subvol at the end
make_mock findmnt 'echo "rw,noatime,compress=zstd:3,ssd,subvol=/root-20250601-120000"'
result_raw=$(get_current_subvol_raw)
assert_eq "get_current_subvol_raw" "/root-20250601-120000" "$result_raw"

result=$(get_current_subvol)
assert_eq "get_current_subvol strips slash" "root-20250601-120000" "$result"

# Subvol without leading slash
make_mock findmnt 'echo "rw,subvol=root-20250601-120000"'
result=$(get_current_subvol)
assert_eq "get_current_subvol without slash" "root-20250601-120000" "$result"

# subvol in the middle of options (not last)
make_mock findmnt 'echo "rw,noatime,subvol=/myroot,compress=zstd"'
result_raw=$(get_current_subvol_raw)
assert_eq "subvol in middle of options" "/myroot" "$result_raw"


# ── get_root_device ──────────────────────────────────────────

section "get_root_device"

# Clear cache
_ROOT_DEVICE=""

# Make python3 return a path that actually exists on the filesystem
mkdir -p "${TESTDIR}/fake_dev"
touch "${TESTDIR}/fake_dev/root_crypt"
make_mock python3 "echo '${TESTDIR}/fake_dev/root_crypt'"

result=$(get_root_device)
assert_eq "get_root_device from python" "${TESTDIR}/fake_dev/root_crypt" "$result"

# Test caching: first call ran in subshell $(), so parent
# _ROOT_DEVICE is still empty.  Set it manually to test
# that the cache prevents re-calling python3.
_ROOT_DEVICE="${TESTDIR}/fake_dev/root_crypt"
make_mock python3 'echo "/dev/should_not_be_called"'
result=$(get_root_device)
assert_eq "get_root_device cached" "${TESTDIR}/fake_dev/root_crypt" "$result"

# Test error case: python3 returns empty, MAPPER_NAME doesn't resolve
_ROOT_DEVICE=""
make_mock python3 'echo ""'
MAPPER_NAME="nonexistent_mapper_xyz_$$"
run_cmd get_root_device
assert_eq "get_root_device fails when nothing found" "1" "$_rc"
assert_contains "error message on failure" "Cannot detect" "$_out"
MAPPER_NAME="root_crypt"


# ── ensure_btrfs_mounted ────────────────────────────────────

section "ensure_btrfs_mounted"

BTRFS_MOUNT="${TESTDIR}/mnt_btrfs"
_ROOT_DEVICE="${TESTDIR}/fake_dev/root_crypt"

# Already mounted
make_mock mountpoint 'exit 0'
assert_rc "already mounted → rc 0" 0 ensure_btrfs_mounted
[[ -d "$BTRFS_MOUNT" ]] && ok "creates mount dir" || fail "didn't create mount dir"

# Not mounted, mount succeeds
make_mock mountpoint 'exit 1'
make_mock mount      'exit 0'
assert_rc "mount succeeds → rc 0" 0 ensure_btrfs_mounted

# Not mounted, mount fails
make_mock mountpoint 'exit 1'
make_mock mount      'exit 1'
run_cmd ensure_btrfs_mounted
assert_eq "mount fails → rc 1" "1" "$_rc"
assert_contains "mount error" "Failed to mount" "$_out"

# Restore
make_mock mountpoint 'exit 0'
make_mock mount      'exit 0'


# ── validate_subvolume ──────────────────────────────────────

section "validate_subvolume"

BTRFS_MOUNT="${TESTDIR}/mnt_val"
mkdir -p "${BTRFS_MOUNT}/root-20250601-120000"
make_mock mountpoint 'exit 0'
make_mock btrfs      'exit 0'

assert_rc "valid subvolume"    0 validate_subvolume "root-20250601-120000" "$BTRFS_MOUNT"
assert_rc "empty subvol name"  1 validate_subvolume "" "$BTRFS_MOUNT"
assert_rc "nonexistent subvol" 1 validate_subvolume "root-nonexistent" "$BTRFS_MOUNT"


summary
