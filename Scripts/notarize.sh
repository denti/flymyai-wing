#!/bin/bash
# notarytool + stapler. Requires an App Store Connect API key in the environment.
#
# The API key rather than --apple-id/--password: it does not break when the Apple ID's 2FA
# state changes, which is the failure that strands a release at 3 a.m.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${APP_NAME:-Lidwing}"
: "${AC_KEY:?App Store Connect key (base64) required}"
: "${AC_KEY_ID:?}"
: "${AC_ISSUER:?}"

KEYFILE="${RUNNER_TEMP:-/tmp}/ac.p8"
trap 'rm -f "$KEYFILE"' EXIT
echo "$AC_KEY" | base64 --decode > "$KEYFILE"

ARCHIVE="${RUNNER_TEMP:-/tmp}/notarize.zip"
ditto -c -k --sequesterRsrc --keepParent "dist/$APP.app" "$ARCHIVE"

xcrun notarytool submit "$ARCHIVE" \
  --key "$KEYFILE" --key-id "$AC_KEY_ID" --issuer "$AC_ISSUER" \
  --wait --timeout 30m --output-format json | tee "${RUNNER_TEMP:-/tmp}/notarize.json"

python3 - "${RUNNER_TEMP:-/tmp}/notarize.json" <<'PY'
import json, sys
status = json.load(open(sys.argv[1]))["status"]
print("notarization status:", status)
sys.exit(0 if status == "Accepted" else 1)
PY

xcrun stapler staple "dist/$APP.app"
xcrun stapler validate "dist/$APP.app"
