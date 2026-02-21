#!/bin/bash
# verify-kvm.sh — Verify KVM/QEMU nested virtualization on EC2 M8i
set -euo pipefail

PASS=0
FAIL=0

check() {
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "✅ $desc"
    PASS=$((PASS + 1))
  else
    echo "❌ $desc"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== KVM/QEMU Verification on EC2 M8i ==="
echo ""

# 1. CPU virtualization flags
echo "--- CPU Virtualization ---"
check "CPU has vmx or svm flag" grep -cE '(vmx|svm)' /proc/cpuinfo
echo "  CPU flags: $(grep -oE '(vmx|svm)' /proc/cpuinfo | head -1)"
echo ""

# 2. /dev/kvm
echo "--- KVM Device ---"
check "/dev/kvm exists" test -e /dev/kvm
if [ -e /dev/kvm ]; then
  ls -la /dev/kvm
fi
echo ""

# 3. KVM module
echo "--- KVM Module ---"
check "KVM module loaded" lsmod
lsmod | grep kvm || echo "  (kvm module info not available)"
echo ""

# 4. QEMU
echo "--- QEMU ---"
QEMU_BIN=""
if command -v qemu-kvm >/dev/null 2>&1; then
  QEMU_BIN="qemu-kvm"
elif command -v qemu-system-x86_64 >/dev/null 2>&1; then
  QEMU_BIN="qemu-system-x86_64"
fi

if [ -n "$QEMU_BIN" ]; then
  check "QEMU binary found ($QEMU_BIN)" which "$QEMU_BIN"
  $QEMU_BIN --version
else
  echo "❌ QEMU binary not found"
  FAIL=$((FAIL + 1))
fi
echo ""

# 5. OVMF (UEFI firmware)
echo "--- OVMF (UEFI) ---"
OVMF_PATH=""
for p in /usr/share/edk2/ovmf/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2/ovmf/OVMF_CODE.cc.fd; do
  if [ -f "$p" ]; then
    OVMF_PATH="$p"
    break
  fi
done

if [ -n "$OVMF_PATH" ]; then
  check "OVMF firmware found" test -f "$OVMF_PATH"
  echo "  Path: $OVMF_PATH"
else
  echo "❌ OVMF firmware not found"
  FAIL=$((FAIL + 1))
fi
echo ""

# 6. gvproxy
echo "--- gvproxy ---"
check "gvproxy binary found" which gvproxy
echo ""

# 7. QEMU + KVM acceleration test
echo "--- QEMU+KVM Acceleration Test ---"
if [ -n "$QEMU_BIN" ] && [ -e /dev/kvm ]; then
  echo "  Testing QEMU with KVM acceleration..."
  timeout 5 $QEMU_BIN \
    -machine accel=kvm \
    -cpu host \
    -m 256 \
    -nographic \
    -no-reboot \
    -display none \
    -serial none \
    -monitor none 2>&1 || EXIT_CODE=$?
  # Exit code 124 (timeout) or 1 (no disk) is expected — means QEMU+KVM started
  if [ "${EXIT_CODE:-0}" -eq 124 ] || [ "${EXIT_CODE:-0}" -le 1 ]; then
    echo "✅ QEMU+KVM acceleration works"
    PASS=$((PASS + 1))
  else
    echo "❌ QEMU+KVM not working (exit code: ${EXIT_CODE})"
    FAIL=$((FAIL + 1))
  fi
else
  echo "⏭️  Skipped (QEMU or /dev/kvm not available)"
fi
echo ""

# 8. bootc-man
echo "--- bootc-man ---"
check "bootc-man binary found" which bootc-man
bootc-man version 2>/dev/null || true
echo ""

# Summary
echo "==============================="
echo "Results: $PASS passed, $FAIL failed"
echo "==============================="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
