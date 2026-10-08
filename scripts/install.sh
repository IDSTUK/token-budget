#!/bin/sh
# Build, install to /Applications, and (re)launch.
set -eu
cd "$(dirname "$0")/.."
scripts/bundle.sh

# Retire the app's old name (Claude Budget Rings). Same bundle ID, so the
# Keychain token and settings carry over; re-register the login item at the
# new path on first launch.
if [ -d "/Applications/Claude Budget Rings.app" ]; then
  pkill -x ClaudeBudgetRings 2>/dev/null || true
  rm -rf "/Applications/Claude Budget Rings.app"
  defaults delete com.domkits.claude-budget-rings chrome.loginItemInitialised 2>/dev/null || true
fi

pkill -x TokenBudget 2>/dev/null || true
# Wait for the old instance to exit, or `open` races it and fails with -600.
i=0; while { pgrep -x TokenBudget || pgrep -x ClaudeBudgetRings; } >/dev/null && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
rm -rf "/Applications/Token Budget.app"
cp -R "build/Token Budget.app" /Applications/
open "/Applications/Token Budget.app"
echo "Installed to /Applications/Token Budget.app"
