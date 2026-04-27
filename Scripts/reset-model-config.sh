#!/usr/bin/env bash
# Reset only model/provider state — leaves TCC grants intact so onboarding
# jumps straight past the permission cards into the model picker. Useful
# when iterating on the provider/onboard UI without re-granting Screen
# Recording + Accessibility every loop.
#
# Wiped:
#   - ~/.aos/config.json              (selection, effort, hasCompletedOnboarding)
#   - ~/.aos/auth/                    (chatgpt.json OAuth token)
#   - Keychain entries under service "com.aos.apikey" (DeepSeek + future apiKey providers)
#
# Not touched:
#   - TCC ScreenCapture / Accessibility grants
#   - ~/.aos/run/ and any workspaces
#   - The AOS.app bundle, signing identity, anything else
set -euo pipefail

BUNDLE_ID="com.aos.shell"
AOS_HOME="${HOME}/.aos"
APIKEY_SERVICE="com.aos.apikey"

echo "==> Quitting AOS if running"
pkill -x AOS 2>/dev/null || true
sleep 0.4

echo "==> Removing ${AOS_HOME}/config.json"
rm -f "${AOS_HOME}/config.json"

echo "==> Removing ${AOS_HOME}/auth/"
rm -rf "${AOS_HOME}/auth"

echo "==> Clearing Keychain API keys (service=${APIKEY_SERVICE})"
# `security delete-generic-password` removes one entry per call and exits
# non-zero when nothing matches — loop until empty so we catch every
# provider id stored under the same service.
while security delete-generic-password -s "${APIKEY_SERVICE}" >/dev/null 2>&1; do
    echo "    removed one"
done
echo "    done"

echo
echo "Done. TCC grants for ${BUNDLE_ID} were left in place."
echo "Re-run Scripts/run.sh to land directly in the provider picker."
