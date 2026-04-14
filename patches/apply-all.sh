#!/usr/bin/env bash
# apply-all.sh — Apply all Cipher 0.3.0 patches after npm install/update
#
# Patches:
#   1. Significance filter bypass (return true) — prevents silent content discard
#   2. STDIO console redirect (console.log → stderr) — prevents MCP crash
#
# Usage: bash patches/apply-all.sh
# Run after: npm install -g @byterover/cipher, npm update, or Node version change
set -euo pipefail

# Locate Cipher installation
CIPHER_BIN=$(which cipher 2>/dev/null || true)
if [ -z "$CIPHER_BIN" ]; then
    echo "ERROR: cipher binary not found in PATH"
    exit 1
fi

CIPHER_DIR="$(dirname "$CIPHER_BIN")/../lib/node_modules/@byterover/cipher/dist/src"
CIPHER_CORE="$CIPHER_DIR/core/index.cjs"
CIPHER_APP="$CIPHER_DIR/app/index.cjs"

# Verify files exist
for f in "$CIPHER_CORE" "$CIPHER_APP"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: $f not found"
        exit 1
    fi
done

echo "Cipher installation: $CIPHER_DIR"
echo ""

# --- Patch 1: Significance Filter Bypass ---
echo "=== Patch 1: Significance Filter Bypass ==="

PATCH1_APPLIED=0
for f in "$CIPHER_CORE" "$CIPHER_APP"; do
    if grep -q "function isSignificantKnowledge(content) { return true;" "$f"; then
        echo "  $(basename $(dirname "$f"))/$(basename "$f"): already patched"
    else
        sed -i 's/function isSignificantKnowledge(content) {/function isSignificantKnowledge(content) { return true;/' "$f"
        sed -i 's/function isWorkspaceSignificantContent(content) {/function isWorkspaceSignificantContent(content) { return true;/' "$f"
        echo "  $(basename $(dirname "$f"))/$(basename "$f"): PATCHED"
        PATCH1_APPLIED=1
    fi
done

if [ "$PATCH1_APPLIED" -eq 0 ]; then
    echo "  Status: already applied"
else
    echo "  Status: applied"
fi
echo ""

# --- Patch 2: STDIO Console Redirect ---
echo "=== Patch 2: STDIO Console Redirect ==="

if grep -q "redirect stray console.log" "$CIPHER_APP"; then
    echo "  app/index.cjs: already patched"
    echo "  Status: already applied"
else
    sed -i '/^async function startMcpMode(agent, opts) {$/a\  // PATCH: redirect stray console.log/info/warn to stderr to prevent stdout MCP corruption\n  console.log = (...args) => process.stderr.write(args.map(String).join('"'"' '"'"') + '"'"'\\n'"'"');\n  console.info = console.log;\n  console.warn = console.log;' "$CIPHER_APP"
    echo "  app/index.cjs: PATCHED"
    echo "  Status: applied"
fi
echo ""

# --- Verification ---
echo "=== Verification ==="

ERRORS=0

# Check significance filter
for f in "$CIPHER_CORE" "$CIPHER_APP"; do
    LABEL="$(basename $(dirname "$f"))/$(basename "$f")"
    if grep -q "function isSignificantKnowledge(content) { return true;" "$f"; then
        echo "  $LABEL: significance filter — OK"
    else
        echo "  $LABEL: significance filter — FAILED"
        ERRORS=$((ERRORS + 1))
    fi
done

# Check STDIO redirect
if grep -q "redirect stray console.log" "$CIPHER_APP"; then
    echo "  app/index.cjs: stdio redirect — OK"
else
    echo "  app/index.cjs: stdio redirect — FAILED"
    ERRORS=$((ERRORS + 1))
fi

echo ""
if [ "$ERRORS" -eq 0 ]; then
    echo "All patches verified successfully."
else
    echo "WARNING: $ERRORS verification(s) failed. Check output above."
    exit 1
fi
