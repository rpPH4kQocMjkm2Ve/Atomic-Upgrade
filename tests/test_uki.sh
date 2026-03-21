#!/usr/bin/env bash
# tests/test_uki.sh — UKI signing, verification, and build
# Run: bash tests/test_uki.sh

source "$(dirname "${BASH_SOURCE[0]}")/test_harness.sh"


# ── sign_uki / verify_uki ───────────────────────────────────

section "sign_uki / verify_uki"

# SBCTL_SIGN=0 → skip signing
SBCTL_SIGN=0
run_cmd sign_uki "/fake/path.efi"
assert_contains "sign skip message" "Skipping" "$_out"

# SBCTL_SIGN=1 → call sbctl sign
SBCTL_SIGN=1
make_mock sbctl 'exit 0'
run_cmd sign_uki "/fake/path.efi"
assert_eq "sign success → rc 0" "0" "$_rc"
assert_contains "sign calls sbctl" "Signing" "$_out"

# sbctl sign fails → propagate error
make_mock sbctl 'exit 1'
run_cmd sign_uki "/fake/path.efi"
assert_eq "sign failure → rc 1" "1" "$_rc"

# verify with SBCTL_SIGN=1
make_mock sbctl 'exit 0'
run_cmd verify_uki "/fake/path.efi"
assert_contains "verify calls sbctl" "Verifying" "$_out"

# verify with SBCTL_SIGN=0 → silent no-op
SBCTL_SIGN=0
run_cmd verify_uki "/fake/path.efi"
assert_eq "verify skipped when SBCTL_SIGN=0" "" "$_out"


# ── build_uki ──────────────────────────────────────────────────

section "build_uki"

_BU_ROOT="${TESTDIR}/bu_newroot"
_BU_ESP="${TESTDIR}/bu_esp"
_BU_LOG="${TESTDIR}/bu_ukify_log"
KERNEL_PKG="linux"
KERNEL_PARAMS="rw quiet"

# Helper: create a clean snapshot structure
_bu_setup() {
    rm -rf "$_BU_ROOT" "$_BU_ESP"
    ESP="$_BU_ESP"
    mkdir -p "${_BU_ESP}/EFI/Linux"
    mkdir -p "${_BU_ROOT}/boot"
    mkdir -p "${_BU_ROOT}/etc"
    mkdir -p "${_BU_ROOT}/usr/lib/modules/6.12.5-arch1-1"
    touch "${_BU_ROOT}/boot/vmlinuz-linux"
    touch "${_BU_ROOT}/boot/initramfs-linux.img"
    cat > "${_BU_ROOT}/etc/os-release" <<'OSREL'
NAME="Arch Linux"
PRETTY_NAME="Arch Linux"
ID=arch
OSREL
    echo "linux" > "${_BU_ROOT}/usr/lib/modules/6.12.5-arch1-1/pkgbase"
    rm -f "$_BU_LOG"
}

# Mock python3: return root cmdline when called with rootdev.py
_bu_mock_python() {
    make_mock python3 '
if [[ "$1" == *"rootdev.py" && "${2:-}" == "cmdline" ]]; then
    echo "root=/dev/mapper/root_crypt rootflags=subvol=$3"
    exit 0
fi
echo ""
'
}

# Mock ukify: log args + os-release content, create output file
_bu_mock_ukify() {
    make_mock ukify '
echo "ARGS: $*" > "'"${_BU_LOG}"'"
for arg in "$@"; do
    case "$arg" in
        --output=*) touch "${arg#--output=}" ;;
        --os-release=@*)
            echo "OS_RELEASE:" >> "'"${_BU_LOG}"'"
            cat "${arg#--os-release=@}" >> "'"${_BU_LOG}"'" 2>/dev/null
            ;;
    esac
done
'
}

# ── Happy path ──
_bu_setup; _bu_mock_python; _bu_mock_ukify
run_cmd build_uki "20250701-120000" "$_BU_ROOT" "root-20250701-120000"
assert_eq "build_uki happy path → rc 0" "0" "$_rc"
assert_contains "returns uki path" "arch-20250701-120000.efi" "$_out"
[[ -f "${_BU_ESP}/EFI/Linux/arch-20250701-120000.efi" ]] \
    && ok "UKI file created on disk" || fail "UKI file not on disk"

# ── Missing kernel ──
_bu_setup; _bu_mock_python; _bu_mock_ukify
rm -f "${_BU_ROOT}/boot/vmlinuz-linux"
run_cmd build_uki "20250701-120000" "$_BU_ROOT" "root-20250701-120000"
assert_eq "missing kernel → rc 1" "1" "$_rc"
assert_contains "kernel error" "No kernel" "$_out"

# ── Missing initramfs ──
_bu_setup; _bu_mock_python; _bu_mock_ukify
rm -f "${_BU_ROOT}/boot/initramfs-linux.img"
run_cmd build_uki "20250701-120000" "$_BU_ROOT" "root-20250701-120000"
assert_eq "missing initramfs → rc 1" "1" "$_rc"
assert_contains "initramfs error" "No initramfs" "$_out"

# ── Missing os-release ──
_bu_setup; _bu_mock_python; _bu_mock_ukify
rm -f "${_BU_ROOT}/etc/os-release"
run_cmd build_uki "20250701-120000" "$_BU_ROOT" "root-20250701-120000"
assert_eq "missing os-release → rc 1" "1" "$_rc"
assert_contains "os-release error" "No os-release" "$_out"

# ── rootdev.py cmdline fails ──
_bu_setup; _bu_mock_ukify
make_mock python3 'exit 1'
run_cmd build_uki "20250701-120000" "$_BU_ROOT" "root-20250701-120000"
assert_eq "rootdev.py fails → rc 1" "1" "$_rc"
assert_contains "cmdline error" "Cannot detect root device" "$_out"

# ── ukify build fails ──
_bu_setup; _bu_mock_python
make_mock ukify 'exit 1'
run_cmd build_uki "20250701-120000" "$_BU_ROOT" "root-20250701-120000"
assert_eq "ukify fails → rc 1" "1" "$_rc"
assert_contains "ukify error" "ukify build failed" "$_out"

# ── ukify succeeds but doesn't create output file ──
_bu_setup; _bu_mock_python
make_mock ukify 'exit 0'
run_cmd build_uki "20250701-120000" "$_BU_ROOT" "root-20250701-120000"
assert_eq "ukify no output → rc 1" "1" "$_rc"
assert_contains "not created" "UKI not created" "$_out"

# ── Kernel version via pkgbase → --uname passed ──
_bu_setup; _bu_mock_python; _bu_mock_ukify
run_cmd build_uki "20250701-120000" "$_BU_ROOT" "root-20250701-120000"
_ukify_args=$(cat "$_BU_LOG" 2>/dev/null || echo "")
assert_contains "pkgbase → --uname" "--uname=6.12.5-arch1-1" "$_ukify_args"

# ── Kernel version fallback (no pkgbase, dir name matches ^[0-9]+\.) ──
_bu_setup; _bu_mock_python; _bu_mock_ukify
rm -f "${_BU_ROOT}/usr/lib/modules/6.12.5-arch1-1/pkgbase"
run_cmd build_uki "20250701-120000" "$_BU_ROOT" "root-20250701-120000"
assert_eq "fallback version → rc 0" "0" "$_rc"
_ukify_args=$(cat "$_BU_LOG" 2>/dev/null || echo "")
assert_contains "fallback → --uname" "--uname=6.12.5-arch1-1" "$_ukify_args"

# ── No modules directory → no --uname ──
_bu_setup; _bu_mock_python; _bu_mock_ukify
rm -rf "${_BU_ROOT}/usr/lib/modules"
run_cmd build_uki "20250701-120000" "$_BU_ROOT" "root-20250701-120000"
assert_eq "no modules dir → rc 0" "0" "$_rc"
_ukify_args=$(cat "$_BU_LOG" 2>/dev/null || echo "")
assert_not_contains "no --uname without modules" "--uname" "$_ukify_args"

# ── Modules dir exists but no pkgbase match, no version-like dirs ──
_bu_setup; _bu_mock_python; _bu_mock_ukify
rm -f "${_BU_ROOT}/usr/lib/modules/6.12.5-arch1-1/pkgbase"
mv "${_BU_ROOT}/usr/lib/modules/6.12.5-arch1-1" \
   "${_BU_ROOT}/usr/lib/modules/extramodules-6.12"
run_cmd build_uki "20250701-120000" "$_BU_ROOT" "root-20250701-120000"
assert_eq "no version match → rc 0" "0" "$_rc"
_ukify_args=$(cat "$_BU_LOG" 2>/dev/null || echo "")
assert_not_contains "no --uname with non-version dir" "--uname" "$_ukify_args"

# ── Multiple module dirs: pkgbase selects correct one ──
_bu_setup; _bu_mock_python; _bu_mock_ukify
mkdir -p "${_BU_ROOT}/usr/lib/modules/6.11.0-lts"
echo "linux-lts" > "${_BU_ROOT}/usr/lib/modules/6.11.0-lts/pkgbase"
run_cmd build_uki "20250701-120000" "$_BU_ROOT" "root-20250701-120000"
assert_eq "multi-module → rc 0" "0" "$_rc"
_ukify_args=$(cat "$_BU_LOG" 2>/dev/null || echo "")
assert_contains "selects correct version" "--uname=6.12.5-arch1-1" "$_ukify_args"
assert_not_contains "rejects wrong version" "--uname=6.11.0-lts" "$_ukify_args"

# ── PRETTY_NAME rewritten with gen_id ──
_bu_setup; _bu_mock_python; _bu_mock_ukify
run_cmd build_uki "20250701-120000" "$_BU_ROOT" "root-20250701-120000"
_ukify_log=$(cat "$_BU_LOG" 2>/dev/null || echo "")
assert_contains "PRETTY_NAME rewritten" 'Arch Linux (20250701-120000)' "$_ukify_log"

# ── cmdline composition: root device + subvol + kernel params ──
_bu_setup; _bu_mock_python; _bu_mock_ukify
run_cmd build_uki "20250701-120000" "$_BU_ROOT" "root-20250701-120000"
_ukify_args=$(cat "$_BU_LOG" 2>/dev/null || echo "")
assert_contains "cmdline has root device" "root=/dev/mapper/root_crypt" "$_ukify_args"
assert_contains "cmdline has subvol" "rootflags=subvol=root-20250701-120000" "$_ukify_args"
assert_contains "cmdline has kernel params" "rw quiet" "$_ukify_args"

# ── Correct --linux, --initrd, --output paths ──
_bu_setup; _bu_mock_python; _bu_mock_ukify
run_cmd build_uki "20250701-120000" "$_BU_ROOT" "root-20250701-120000"
_ukify_args=$(cat "$_BU_LOG" 2>/dev/null || echo "")
assert_contains "--linux path" "--linux=${_BU_ROOT}/boot/vmlinuz-linux" "$_ukify_args"
assert_contains "--initrd path" "--initrd=${_BU_ROOT}/boot/initramfs-linux.img" "$_ukify_args"
assert_contains "--output path" "--output=${_BU_ESP}/EFI/Linux/arch-20250701-120000.efi" "$_ukify_args"

# ── Custom KERNEL_PKG ──
_bu_setup; _bu_mock_python; _bu_mock_ukify
KERNEL_PKG="linux-zen"
mkdir -p "${_BU_ROOT}/usr/lib/modules/6.12.5-zen1-1"
echo "linux-zen" > "${_BU_ROOT}/usr/lib/modules/6.12.5-zen1-1/pkgbase"
touch "${_BU_ROOT}/boot/vmlinuz-linux-zen"
touch "${_BU_ROOT}/boot/initramfs-linux-zen.img"
run_cmd build_uki "20250701-120000" "$_BU_ROOT" "root-20250701-120000"
assert_eq "custom KERNEL_PKG → rc 0" "0" "$_rc"
_ukify_args=$(cat "$_BU_LOG" 2>/dev/null || echo "")
assert_contains "zen kernel" "vmlinuz-linux-zen" "$_ukify_args"
assert_contains "zen initramfs" "initramfs-linux-zen.img" "$_ukify_args"
assert_contains "zen uname" "--uname=6.12.5-zen1-1" "$_ukify_args"
KERNEL_PKG="linux"

# ── Tagged gen_id (e.g. 20250701-120000-kde) ──
_bu_setup; _bu_mock_python; _bu_mock_ukify
run_cmd build_uki "20250701-120000-kde" "$_BU_ROOT" "root-20250701-120000-kde"
assert_eq "tagged gen_id → rc 0" "0" "$_rc"
assert_contains "tagged uki filename" "arch-20250701-120000-kde.efi" "$_out"
_ukify_log=$(cat "$_BU_LOG" 2>/dev/null || echo "")
assert_contains "tagged PRETTY_NAME" "Arch Linux (20250701-120000-kde)" "$_ukify_log"

# Restore defaults
KERNEL_PKG="linux"
KERNEL_PARAMS="rw slab_nomerge init_on_alloc=1 page_alloc.shuffle=1 pti=on vsyscall=none randomize_kstack_offset=on debugfs=off"
make_mock python3 'echo ""'
make_mock ukify   'exit 0'


summary
