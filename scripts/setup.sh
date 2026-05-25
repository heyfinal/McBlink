#!/bin/bash
# McBlink project setup script
# Run once after cloning to bootstrap the Xcode project and local storage tree.
# Make executable: chmod +x scripts/setup.sh

set -e

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUPPORT_DIR="$HOME/Library/Application Support/McBlink"

echo "=== McBlink Setup ==="
echo "Repo: $REPO_DIR"
echo ""

# ------------------------------------------------------------------
# 1. Ensure xcodegen is installed
# ------------------------------------------------------------------
if ! command -v xcodegen &>/dev/null; then
    echo "[1/4] xcodegen not found — installing via Homebrew..."
    if ! command -v brew &>/dev/null; then
        echo "ERROR: Homebrew is required. Install it from https://brew.sh then re-run this script."
        exit 1
    fi
    brew install xcodegen
else
    echo "[1/4] xcodegen found: $(xcodegen --version 2>/dev/null || echo 'version unknown')"
fi

# ------------------------------------------------------------------
# 2. Generate the Xcode project from project.yml
# ------------------------------------------------------------------
echo ""
echo "[2/4] Running xcodegen generate..."
cd "$REPO_DIR"
xcodegen generate --spec project.yml --project "$REPO_DIR"
echo "      McBlink.xcodeproj generated."

# ------------------------------------------------------------------
# 3. Create local storage directory tree
# ------------------------------------------------------------------
echo ""
echo "[3/4] Creating Application Support directory tree..."
DIRS=(
    "$SUPPORT_DIR/clips"
    "$SUPPORT_DIR/snapshots"
    "$SUPPORT_DIR/db"
    "$SUPPORT_DIR/models"
    "$SUPPORT_DIR/profiles"
)
for d in "${DIRS[@]}"; do
    mkdir -p "$d"
    echo "      $d"
done

# ------------------------------------------------------------------
# 4. Print signing instructions
# ------------------------------------------------------------------
echo ""
echo "[4/4] === NEXT STEPS — Code Signing ==="
echo ""
echo "  1. Open McBlink.xcodeproj in Xcode:"
echo "     open \"$REPO_DIR/McBlink.xcodeproj\""
echo ""
echo "  2. For each target (McBlinkApp, SentinelCore, SentinelWatchdog):"
echo "     - Select the target in the Project Navigator"
echo "     - Open the 'Signing & Capabilities' tab"
echo "     - Set 'Signing Certificate' to your Apple Developer certificate"
echo "     - Set 'Team' to your development team"
echo ""
echo "  3. The targets use CODE_SIGN_STYLE = Manual so Xcode will not"
echo "     overwrite your signing choices on next build."
echo ""
echo "  4. For distribution, set CODE_SIGN_STYLE = Automatic and enable"
echo "     Hardened Runtime in each target's build settings."
echo ""
echo "=== Setup complete. ==="
