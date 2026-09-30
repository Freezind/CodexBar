#!/usr/bin/env bash
# Builds, signs, notarizes, and drafts a GitHub release of the AIUsageBar fork.
#
# Usage: Scripts/release_fork.sh <tag> [--publish]
#   <tag>      Release tag, e.g. v0.69.1-aiusagebar.1
#   --publish  Publish immediately instead of creating a draft release.
#
# Requirements (all stay in the Keychain; this script never reads secrets):
#   - A "Developer ID Application" certificate matching FORK_APP_IDENTITY (fork.env).
#   - FORK_TEAM_ID set in fork.env.
#   - A notarytool profile: xcrun notarytool store-credentials "$FORK_NOTARY_PROFILE" --key ... --key-id ... --issuer ...
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
# shellcheck source=/dev/null
source "$ROOT/fork.env"
# shellcheck source=/dev/null
source "$ROOT/version.env"

TAG="${1:-}"
PUBLISH=0
if [[ "${2:-}" == "--publish" ]]; then
  PUBLISH=1
fi
if [[ -z "$TAG" ]]; then
  echo "Usage: $0 <tag> [--publish]" >&2
  exit 1
fi
if [[ -z "${FORK_TEAM_ID:-}" ]]; then
  echo "ERROR: Set FORK_TEAM_ID in fork.env (your Developer ID team)." >&2
  exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
  echo "ERROR: Working tree is not clean; commit or stash before releasing." >&2
  exit 1
fi
if gh release view "$TAG" --repo "$FORK_REPO" >/dev/null 2>&1; then
  echo "ERROR: Release $TAG already exists in $FORK_REPO." >&2
  exit 1
fi

ARCHES="${ARCHES:-arm64}"
OUT_DIR="$ROOT/.build/fork-release"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

echo "==> Packaging ${FORK_APP_NAME} ${MARKETING_VERSION} (${ARCHES})"
ARCHES="$ARCHES" CODEXBAR_SIGNING=identity APP_IDENTITY="$FORK_APP_IDENTITY" APP_TEAM_ID="$FORK_TEAM_ID" \
  ./Scripts/package_app.sh release

APP="$OUT_DIR/${FORK_APP_NAME}.app"
# Renaming the bundle directory does not affect its code signature.
ditto "$ROOT/CodexBar.app" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Notarizing"
NOTARY_ZIP="$OUT_DIR/notarize.zip"
ditto --norsrc -c -k --keepParent "$APP" "$NOTARY_ZIP"
xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$FORK_NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"

xattr -cr "$APP"
find "$APP" -name '._*' -delete
ZIP="$OUT_DIR/${FORK_APP_NAME}-${TAG#v}-macos-${ARCHES// /-}.zip"
ditto --norsrc -c -k --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP" | tee "$ZIP.sha256"

NOTES="$OUT_DIR/notes.md"
cat > "$NOTES" <<NOTES
**${FORK_APP_NAME}** is an unofficial fork of CodexBar by Peter Steinberger (MIT License) that adds opt-in
**5-hour session auto-start** for Codex and Claude. It is never merged upstream; see the README for why.

- Based on upstream CodexBar ${MARKETING_VERSION}. Apple Silicon (${ARCHES}) only. Signed with Developer ID and notarized.
- No automatic updates: download new releases from this page.
- Enable it in Settings → Providers → Codex / Claude → **Auto-start 5h session** (off by default, subscription sign-ins only).
- Claude usage via OAuth: add ${FORK_APP_NAME} to the Access Control list of the \`Claude Code-credentials\` item in
  Keychain Access; otherwise Claude usage falls back to the Claude CLI.
- Please report issues in this repository, not upstream.

Powered by Bonsai.
NOTES

DRAFT_FLAG=(--draft)
if [[ "$PUBLISH" == "1" ]]; then
  DRAFT_FLAG=()
fi
echo "==> Creating GitHub release $TAG in $FORK_REPO"
gh release create "$TAG" "$ZIP" "$ZIP.sha256" \
  --repo "$FORK_REPO" \
  --target "$(git rev-parse HEAD)" \
  --title "${FORK_APP_NAME} ${TAG#v}" \
  --notes-file "$NOTES" \
  "${DRAFT_FLAG[@]}"
