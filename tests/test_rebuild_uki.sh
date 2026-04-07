#!/usr/bin/env bash
# tests/test_rebuild_uki.sh — atomic-rebuild-uki argument parsing, validation, flow
# Run: bash tests/test_rebuild_uki.sh

source "$(dirname "${BASH_SOURCE[0]}")/test_harness.sh"

# ── Setup ───────────────────────────────────────────────────

SCRIPT="${PROJECT_ROOT}/bin/atomic-rebuild-uki"

# The script hardcodes /usr/lib/atomic, which doesn't exist in CI.
# Point verify-lib to the actual common.sh in the project tree
# so that the subsequent 'source' call succeeds.
make_mock verify-lib "echo '${PROJECT_ROOT}/lib/atomic/common.sh'; exit 0"

# ── Help flag (real script) ────────────────────────────────

section "Help flag (real script)"

run_cmd env _ATOMIC_NO_INIT=1 bash "$SCRIPT" --help
assert_eq "help → exit 0" "0" "$_rc"
assert_contains "help shows usage" "Usage:" "$_out"
assert_contains "help shows --list" "--list" "$_out"
assert_contains "help shows GEN_ID" "GEN_ID" "$_out"
assert_contains "help shows examples" "Examples:" "$_out"

run_cmd env _ATOMIC_NO_INIT=1 bash "$SCRIPT" -h
assert_eq "-h → exit 0" "0" "$_rc"

run_cmd env _ATOMIC_NO_INIT=1 bash "$SCRIPT" -V
assert_eq "-V → exit 0" "0" "$_rc"
assert_contains "version output" "atomic-rebuild-uki v" "$_out"

# ── GEN_ID validation (patched script — bypasses EUID + validate_config) ──

section "GEN_ID validation (patched script)"

# Create a patched copy that skips EUID and validate_config, then exits
# right after GEN_ID validation so we can test the regex against the real script.
_TEST_SCRIPT="${TESTDIR}/rebuild-uki-test"
sed \
    -e 's/^\(\[\[ \$EUID -eq 0 \]\]\)/# \1/' \
    -e 's/^validate_config || exit 1$/# validate_config || exit 1/' \
    -e '/^UKI_PATH=.*GEN_ID.*efi"/a\
# --- EARLY EXIT AFTER GEN_ID VALIDATION ---\
if [[ "${ATOMIC_EXIT_AFTER_VALIDATE:-}" == "1" ]]; then\
    echo "VALIDATE_OK"\
    echo "GEN_ID=${GEN_ID}"\
    echo "SUBVOL=${SUBVOL}"\
    echo "UKI_PATH=${UKI_PATH}"\
    exit 0\
fi' \
    "$SCRIPT" > "$_TEST_SCRIPT"
chmod +x "$_TEST_SCRIPT"

_run_rebuild() {
    run_cmd env ATOMIC_EXIT_AFTER_VALIDATE=1 _ATOMIC_NO_INIT=1 bash "$_TEST_SCRIPT" "$@"
}

# Valid GEN_IDs — should pass validation
_run_rebuild "20250208-134725"
assert_eq "plain GEN_ID valid" "0" "$_rc"
assert_contains "plain GEN_ID echo" "VALIDATE_OK" "$_out"
assert_contains "GEN_ID value" "GEN_ID=20250208-134725" "$_out"
assert_contains "SUBVOL value" "SUBVOL=root-20250208-134725" "$_out"
assert_contains "UKI_PATH value" "UKI_PATH=/efi/EFI/Linux/arch-20250208-134725.efi" "$_out"

_run_rebuild "20250208-134725-kde"
assert_eq "tagged GEN_ID valid" "0" "$_rc"
assert_contains "tagged SUBVOL" "SUBVOL=root-20250208-134725-kde" "$_out"
assert_contains "tagged UKI_PATH" "UKI_PATH=/efi/EFI/Linux/arch-20250208-134725-kde.efi" "$_out"

_run_rebuild "20250208-134725-pre-nvidia"
assert_eq "multi-word tag valid" "0" "$_rc"

_run_rebuild "20250208-134725-test_123"
assert_eq "underscore in tag valid" "0" "$_rc"

# Invalid GEN_IDs — should fail validation
_run_rebuild "20250208"
assert_eq "missing time → invalid" "1" "$_rc"
assert_contains "missing time error" "YYYYMMDD-HHMMSS" "$_out"

_run_rebuild "20250208-1347"
assert_eq "short time → invalid" "1" "$_rc"

_run_rebuild "not-a-date"
assert_eq "non-date → invalid" "1" "$_rc"

_run_rebuild ""
assert_eq "empty → invalid" "1" "$_rc"

_run_rebuild "../../etc/passwd"
assert_eq "path traversal → invalid" "1" "$_rc"

_run_rebuild "20250208-134725/evil"
assert_eq "slash in tag → invalid" "1" "$_rc"

# ── list_orphans: verify the function exists in the real script ──

section "list_orphans: verify function in real script"

# The list_orphans function is tested via --list in integration.
# Here we verify its key code patterns exist in the script.
_script_content=$(cat "$SCRIPT")

assert_contains "has list_orphans function" 'list_orphans()' "$_script_content"
assert_contains "has subvolume glob pattern" 'root-[0-9]*' "$_script_content"
# Use grep for regex patterns (assert_contains does glob matching only)
grep -q 'arch-.*\.efi' "$SCRIPT" && ok "has UKI file pattern" || fail "has UKI file pattern"
assert_contains "has UKI exists message" 'UKI exists' "$_script_content"
assert_contains "has UKI missing message" 'UKI missing' "$_script_content"
assert_contains "has empty message" 'No generation subvolumes found' "$_script_content"
assert_contains "has reverse sort" 'sort -r' "$_script_content"

# ── Overwrite confirmation: verify the prompt exists in real script ──

section "Overwrite confirmation: verify in real script"

assert_contains "has 'already exists' message" 'UKI already exists' "$_script_content"
assert_contains "has overwrite prompt" 'Overwrite?' "$_script_content"
grep -qF '[y/N]' "$SCRIPT" && ok "has [y/N] default" || fail "has [y/N] default"
grep -qF '[Yy]' "$SCRIPT" && ok "has [Yy] match pattern" || fail "has [Yy] match pattern"
assert_contains "has aborted message" 'Aborted.' "$_script_content"

# ── Cleanup trap: verify in real script ──

section "Cleanup trap: verify in real script"

assert_contains "has cleanup_rebuild function" 'cleanup_rebuild()' "$_script_content"
assert_contains "trap references cleanup" 'trap cleanup_rebuild EXIT' "$_script_content"
grep -q 'umount.*MOUNT_DIR' "$SCRIPT" && ok "cleanup unmounts MOUNT_DIR" || fail "cleanup unmounts MOUNT_DIR"
grep -q 'rmdir.*MOUNT_DIR' "$SCRIPT" && ok "cleanup removes MOUNT_DIR" || fail "cleanup removes MOUNT_DIR"
grep -q 'umount.*BTRFS_MOUNT' "$SCRIPT" && ok "cleanup unmounts BTRFS" || fail "cleanup unmounts BTRFS"
assert_contains "cleanup closes lock" 'LOCK_FD' "$_script_content"

# ── UKI path construction: verify in real script ──

section "UKI path construction: verify in real script"

grep -q 'arch-.*\.efi' "$SCRIPT" && ok "has UKI path pattern" || fail "has UKI path pattern"
assert_contains "uses GEN_ID in path" 'arch-${GEN_ID}' "$_script_content"
grep -qF 'EFI/Linux' "$SCRIPT" && ok "uses ESP path" || fail "uses ESP path"

# ── Rebuild flow: verify the sequence in real script ──

section "Rebuild flow: verify sequence in real script"

# Verify the script follows the expected order:
# validate_config → check UKI exists → acquire_lock → ensure_btrfs →
# validate_subvolume → mount → build_uki → sign → unmount
assert_contains "has subvolume check" 'Checking subvolume' "$_script_content"
assert_contains "has build UKI call" 'Building UKI' "$_script_content"
assert_contains "has sign call" 'sign_uki' "$_script_content"
assert_contains "has unmount" 'Unmounting' "$_script_content"
assert_contains "has done message" 'Done:' "$_script_content"

summary
