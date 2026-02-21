#!/bin/bash
# verify-vfkit.sh — Verify vfkit and gvproxy on macOS
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

echo "=== vfkit/gvproxy Verification on macOS ==="
echo ""

# 0. Add Homebrew libexec to PATH (vfkit/gvproxy installed there by brew formula)
BREW_PREFIX="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
if [ -d "${BREW_PREFIX}/libexec/bootc-man" ]; then
  export PATH="${BREW_PREFIX}/libexec/bootc-man:${PATH}"
  echo "Added ${BREW_PREFIX}/libexec/bootc-man to PATH"
fi
echo ""

# 1. System info
echo "--- System Info ---"
echo "  OS: $(sw_vers -productName) $(sw_vers -productVersion)"
echo "  Arch: $(uname -m)"
echo ""

# 2. vfkit
echo "--- vfkit ---"
check "vfkit binary found" which vfkit
if command -v vfkit >/dev/null 2>&1; then
  echo "  Path: $(which vfkit)"
  vfkit --version 2>&1 || true
fi
echo ""

# 3. gvproxy
echo "--- gvproxy ---"
check "gvproxy binary found" which gvproxy
if command -v gvproxy >/dev/null 2>&1; then
  echo "  Path: $(which gvproxy)"
fi
echo ""

# 4. Podman
echo "--- Podman ---"
check "podman binary found" which podman
if command -v podman >/dev/null 2>&1; then
  podman version --format "{{.Version}}" 2>/dev/null || podman --version
fi
echo ""

# 5. bootc-man
echo "--- bootc-man ---"
check "bootc-man binary found" which bootc-man
if command -v bootc-man >/dev/null 2>&1; then
  bootc-man version 2>/dev/null || true
fi
echo ""

# Summary
echo "==============================="
echo "Results: $PASS passed, $FAIL failed"
echo "==============================="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
