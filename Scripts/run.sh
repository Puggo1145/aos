#!/usr/bin/env bash
# Build the AOS.app bundle and launch it.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

./Scripts/build-app.sh
open AOS.app
