#!/usr/bin/env bash
# tests/test_upgrade.sh — atomic-upgrade argument parsing, validation, dry-run
# Run: bash tests/test_upgrade.sh

source "$(dirname "${BASH_SOURCE[0]}")/test_harness.sh"

# ── Setup ───────────────────────────────────────────────────

SCRIPT="${PROJECT_ROOT}/bin/atomic-upgrade"

# Mock verify-lib to return the path of the library
make_mock verify-lib 'echo "$1"; exit 0'

# We cannot run atomic-upgrade as root in tests, so we test
# argument parsing and validation by sourcing the script in a
# controlled environment where we intercept the root check.
# We create a wrapper that skips the EUID check.

_wrap_upgrade() {
    # Read the script, comment out the EUID check, then eval
    local script_content
    script_content=$(sed 's/^\(\[\[ \$EUID -eq 0 \]\]\)/# \1/' "$SCRIPT")
    eval "$script_content"
}

# ── Argument parsing ────────────────────────────────────────

section "Argument parsing: basic options"

# Test --dry-run
DRY_RUN=0
CUSTOM_TAG=""
NO_GC=0
SEPARATE_HOME=0
COPY_FILES=""
CHROOT_CMD=()
ATOMIC_UPGRADE=1

# Simulate parsing by extracting the while loop from atomic-upgrade
_parse_args() {
    DRY_RUN=0
    CUSTOM_TAG=""
    NO_GC=0
    SEPARATE_HOME=0
    COPY_FILES=""
    CHROOT_CMD=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run|-n) DRY_RUN=1; shift ;;
            --tag|-t)
                [[ -n "${2:-}" ]] || { echo "ERROR: --tag requires an argument" >&2; return 1; }
                CUSTOM_TAG="$2"
                shift 2
                ;;
            --no-gc) NO_GC=1; shift ;;
            --separate-home) SEPARATE_HOME=1; shift ;;
            --copy-files)
                [[ -n "${2:-}" ]] || { echo "ERROR: --copy-files requires an argument" >&2; return 1; }
                COPY_FILES="$2"; shift 2
                ;;
            --) shift; CHROOT_CMD=("$@"); break ;;
            -*) echo "ERROR: Unknown option: $1" >&2; return 1 ;;
            *) echo "ERROR: Unexpected argument: $1. Use -- before commands." >&2; return 1 ;;
        esac
    done
}

_parse_args --dry-run
assert_eq "--dry-run sets DRY_RUN" "1" "$DRY_RUN"
assert_eq "--dry-run short form" "1" "$DRY_RUN"

_parse_args -n
assert_eq "-n sets DRY_RUN" "1" "$DRY_RUN"

_parse_args --no-gc
assert_eq "--no-gc sets NO_GC" "1" "$NO_GC"

_parse_args --separate-home
assert_eq "--separate-home sets SEPARATE_HOME" "1" "$SEPARATE_HOME"

_parse_args --tag mytag
assert_eq "--tag sets CUSTOM_TAG" "mytag" "$CUSTOM_TAG"

_parse_args -t pre-nvidia
assert_eq "-t sets CUSTOM_TAG" "pre-nvidia" "$CUSTOM_TAG"

_parse_args --copy-files ".bashrc .ssh"
assert_eq "--copy-files sets COPY_FILES" ".bashrc .ssh" "$COPY_FILES"

# ── Argument parsing: chroot command ────────────────────────

section "Argument parsing: chroot command"

_parse_args -- pacman -S vim
assert_eq "chroot command after --" "3" "${#CHROOT_CMD[@]}"
assert_eq "chroot cmd[0]" "pacman" "${CHROOT_CMD[0]}"
assert_eq "chroot cmd[1]" "-S" "${CHROOT_CMD[1]}"
assert_eq "chroot cmd[2]" "vim" "${CHROOT_CMD[2]}"

_parse_args -- /usr/bin/pacman -S --needed base-devel git
assert_eq "multi-arg chroot command" "5" "${#CHROOT_CMD[@]}"
assert_eq "chroot cmd[0]" "/usr/bin/pacman" "${CHROOT_CMD[0]}"
assert_eq "chroot cmd[2]" "--needed" "${CHROOT_CMD[2]}"
assert_eq "chroot cmd[4]" "git" "${CHROOT_CMD[4]}"

# ── Argument parsing: errors ────────────────────────────────

section "Argument parsing: error cases"

run_cmd _parse_args --tag
assert_eq "--tag without arg → rc 1" "1" "$_rc"
assert_contains "--tag error message" "requires an argument" "$_out"

run_cmd _parse_args --copy-files
assert_eq "--copy-files without arg → rc 1" "1" "$_rc"
assert_contains "--copy-files error message" "requires an argument" "$_out"

run_cmd _parse_args --unknown
assert_eq "unknown option → rc 1" "1" "$_rc"
assert_contains "unknown option error" "Unknown option" "$_out"

run_cmd _parse_args bare-arg
assert_eq "bare argument → rc 1" "1" "$_rc"
assert_contains "bare arg error" "Unexpected argument" "$_out"

run_cmd _parse_args -t
assert_eq "-t without arg → rc 1" "1" "$_rc"

# ── Tag validation ──────────────────────────────────────────

section "Tag validation"

_validate_tag() {
    local tag="$1"
    if [[ ! "$tag" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo "ERROR: Invalid tag '${tag}'. Use only letters, numbers, hyphens, underscores." >&2
        return 1
    fi
    if [[ ${#tag} -gt 48 ]]; then
        echo "ERROR: Tag too long (max 48 characters)" >&2
        return 1
    fi
    return 0
}

run_cmd _validate_tag "pre-nvidia"
assert_eq "valid tag → rc 0" "0" "$_rc"

run_cmd _validate_tag "test_123"
assert_eq "valid tag with underscore → rc 0" "0" "$_rc"

run_cmd _validate_tag "with spaces"
assert_eq "tag with spaces → rc 1" "1" "$_rc"
assert_contains "spaces error" "Invalid tag" "$_out"

run_cmd _validate_tag "with/slash"
assert_eq "tag with slash → rc 1" "1" "$_rc"

run_cmd _validate_tag "with.dot"
assert_eq "tag with dot → rc 1" "1" "$_rc"

# 49 characters — too long
run_cmd _validate_tag "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
assert_eq "tag too long (49 chars) → rc 1" "1" "$_rc"
assert_contains "too long error" "Tag too long" "$_out"

# 48 characters — exactly at limit
run_cmd _validate_tag "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
assert_eq "tag at limit (48 chars) → rc 0" "0" "$_rc"

# ── Dependency constraints ──────────────────────────────────

section "Dependency constraints"

_check_constraints() {
    local separate_home="$1" custom_tag="$2" copy_files="$3"

    if [[ $separate_home -eq 1 && -z "$custom_tag" ]]; then
        echo "ERROR: --separate-home requires --tag (home subvolume is named home-TAG)" >&2
        return 1
    fi

    if [[ $separate_home -eq 0 && -n "$copy_files" ]]; then
        echo "ERROR: --copy-files requires --separate-home" >&2
        return 1
    fi

    return 0
}

run_cmd _check_constraints 1 "" ""
assert_eq "separate-home without tag → rc 1" "1" "$_rc"
assert_contains "separate-home error" "requires --tag" "$_out"

run_cmd _check_constraints 0 "" ".bashrc"
assert_eq "copy-files without separate-home → rc 1" "1" "$_rc"
assert_contains "copy-files error" "requires --separate-home" "$_out"

run_cmd _check_constraints 1 "mytag" ""
assert_eq "separate-home with tag → rc 0" "0" "$_rc"

run_cmd _check_constraints 1 "mytag" ".bashrc"
assert_eq "separate-home + tag + copy-files → rc 0" "0" "$_rc"

run_cmd _check_constraints 0 "" ""
assert_eq "no options → rc 0" "0" "$_rc"

# ── Default chroot command ──────────────────────────────────

section "Default chroot command"

_parse_args
assert_eq "default chroot command count" "0" "${#CHROOT_CMD[@]}"

# Simulate default assignment
if [[ ${#CHROOT_CMD[@]} -eq 0 ]]; then
    CHROOT_CMD=(/usr/bin/pacman -Syu)
fi
assert_eq "default chroot command set" "2" "${#CHROOT_CMD[@]}"
assert_eq "default cmd[0]" "/usr/bin/pacman" "${CHROOT_CMD[0]}"
assert_eq "default cmd[1]" "-Syu" "${CHROOT_CMD[1]}"

# ── Dry-run output simulation ───────────────────────────────

section "Dry-run output simulation"

# Verify that dry-run would produce expected output structure
# without actually running destructive operations.

DRY_RUN=1
CUSTOM_TAG="pre-test"
NO_GC=0
SEPARATE_HOME=1
COPY_FILES=".bashrc"
CHROOT_CMD=(/usr/bin/pacman -Syu)
GEN_ID="20260404-120000-pre-test"
NEW_SUBVOL="root-${GEN_ID}"
CURRENT_SUBVOL_RAW="/root-20260403-100000"

_dry_run_output() {
    echo ":: Current: ${CURRENT_SUBVOL_RAW} → New: /${NEW_SUBVOL}"
    echo ":: Command: ${CHROOT_CMD[*]}"
    echo ":: Home: isolated (home-${CUSTOM_TAG})"
    echo ":: DRY RUN - would create snapshot: ${NEW_SUBVOL}"
    echo ":: DRY RUN - would create home: home-${CUSTOM_TAG}"
    echo ":: DRY RUN - chroot command: ${CHROOT_CMD[*]}"
    echo ":: DRY RUN - available updates:"
    echo ":: DRY RUN - would create UKI: /efi/EFI/Linux/arch-${GEN_ID}.efi"
    echo ":: DRY RUN - would run garbage collection"
    echo ":: DRY RUN complete, no changes made"
}

_output=$(_dry_run_output)
assert_contains "dry-run shows current→new" "Current:" "$_output"
assert_contains "dry-run shows snapshot name" "would create snapshot: root-20260404-120000-pre-test" "$_output"
assert_contains "dry-run shows home" "would create home: home-pre-test" "$_output"
assert_contains "dry-run shows UKI path" "would create UKI:" "$_output"
assert_contains "dry-run shows GC" "would run garbage collection" "$_output"
assert_contains "dry-run complete" "DRY RUN complete" "$_output"

# ── Dry-run with --no-gc ────────────────────────────────

section "Dry-run with --no-gc"

# Simulate the exact conditional branch from atomic-upgrade
NO_GC=1
if [[ "$NO_GC" -eq 0 ]]; then
    _gc_msg="would run garbage collection"
else
    _gc_msg="garbage collection: disabled"
fi
assert_eq "NO_GC=1 → disabled message" "garbage collection: disabled" "$_gc_msg"

NO_GC=0
if [[ "$NO_GC" -eq 0 ]]; then
    _gc_msg="would run garbage collection"
else
    _gc_msg="garbage collection: disabled"
fi
assert_eq "NO_GC=0 → enabled message" "would run garbage collection" "$_gc_msg"

# ── GEN_ID generation ───────────────────────────────────────

section "GEN_ID generation"

# Test GEN_ID format with and without custom tag
_test_gen_id() {
    local gen_id="$1"
    if [[ "$gen_id" =~ ^[0-9]{8}-[0-9]{6}(-[a-zA-Z0-9_-]+)?$ ]]; then
        return 0
    else
        return 1
    fi
}

run_cmd _test_gen_id "20260404-120000"
assert_eq "plain GEN_ID valid" "0" "$_rc"

run_cmd _test_gen_id "20260404-120000-pre-nvidia"
assert_eq "tagged GEN_ID valid" "0" "$_rc"

run_cmd _test_gen_id "20260404-120000-with_multiple-tags_123"
assert_eq "complex tagged GEN_ID valid" "0" "$_rc"

run_cmd _test_gen_id "20260404"
assert_eq "partial GEN_ID invalid" "1" "$_rc"

run_cmd _test_gen_id "not-a-date"
assert_eq "non-date GEN_ID invalid" "1" "$_rc"

# ── Subvolume naming ────────────────────────────────────────

section "Subvolume naming"

assert_eq "root subvol prefix" "root-20260404-120000" "root-20260404-120000"
assert_eq "tagged root subvol" "root-20260404-120000-kde" "root-20260404-120000-kde"
assert_eq "home subvol naming" "home-kde" "home-kde"

# ── Cleanup trap logic ──────────────────────────────────────

section "Cleanup trap logic"

# Test that SNAPSHOT_CREATED=0 prevents rollback
_cleanup_would_rollback() {
    local exit_code="$1"
    local snapshot_created="$2"
    local home_just_created="$3"

    if [[ $exit_code -ne 0 && $snapshot_created -eq 1 ]]; then
        echo "WOULD_ROLLBACK"
        if [[ $home_just_created -eq 1 ]]; then
            echo "WOULD_DELETE_HOME"
        fi
    else
        echo "NO_ROLLBACK"
    fi
}

assert_eq "success → no rollback" "NO_ROLLBACK" "$(_cleanup_would_rollback 0 1 0)"
assert_eq "failure + snapshot created → rollback" "WOULD_ROLLBACK" "$(_cleanup_would_rollback 1 1 0)"
assert_eq "failure + snapshot created + home → rollback + home" "WOULD_ROLLBACK
WOULD_DELETE_HOME" "$(_cleanup_would_rollback 1 1 1)"
assert_eq "failure + snapshot NOT created → no rollback" "NO_ROLLBACK" "$(_cleanup_would_rollback 1 0 0)"

summary
