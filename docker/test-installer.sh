#!/usr/bin/env bash
# Test: verify the self-extracting installer works correctly
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

INSTALLER="librenms-installer.sh"
PASS=0
FAIL=0

check() {
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== LibreNMS Installer Tests ==="
echo ""

# 1. Installer file exists
check "Installer file exists" test -f "$INSTALLER"

# 2. Installer is executable
check "Installer is executable" test -x "$INSTALLER"

# 3. Payload marker exists
check "Payload marker present" grep -q '^__PAYLOAD_BELOW__$' "$INSTALLER"

# 4. Extract payload and verify tar integrity
ARCHIVE_LINE=$(awk '/^__PAYLOAD_BELOW__$/ { print NR + 1; exit }' "$INSTALLER")
check "Payload line found" test -n "$ARCHIVE_LINE"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# 5. Payload is valid tar.gz
check "Payload is valid gzip" bash -c "tail -n +$ARCHIVE_LINE '$INSTALLER' | gzip -t"

# 6. Extract succeeds
tail -n +"$ARCHIVE_LINE" "$INSTALLER" | tar xzf - -C "$TMPDIR"
check "Extraction succeeds" test $? -eq 0

# 7-10. All required files extracted
for f in compose.yml .env.example librenms.env deploy.sh; do
    check "Contains $f" test -f "$TMPDIR/$f"
done

# 11-14. Files match originals
for f in compose.yml .env.example librenms.env deploy.sh; do
    check "$f matches original" diff "$TMPDIR/$f" "$f"
done

# 15. deploy.sh has shebang
check "deploy.sh has shebang" bash -c "head -1 '$TMPDIR/deploy.sh' | grep -q '^#!/usr/bin/env bash'"

# 16. deploy.sh passes syntax check
check "deploy.sh passes bash -n" bash -n "$TMPDIR/deploy.sh"

# 17. Installer header has --help handling
check "Installer supports --help" grep -q '\-\-help' "$INSTALLER"

# 18. Installer header has --extract-only
check "Installer supports --extract-only" grep -q '\-\-extract-only' "$INSTALLER"

# 19. Installer header has --noninteractive passthrough
check "Installer passes --noninteractive" grep -q 'noninteractive' "$INSTALLER"

# 20. Installer checks for root
check "Installer checks EUID" grep -q 'EUID' "$INSTALLER"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
