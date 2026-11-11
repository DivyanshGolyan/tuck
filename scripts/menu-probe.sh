#!/bin/bash
# Build only: does not launch an app, request AX access, or modify any installed app.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p artifacts/menu-recovery
xcrun swiftc -swift-version 5 -parse-as-library -D MENU_PROBE_STANDALONE scripts/MenuProbe.swift -o artifacts/menu-recovery/probe-executable
xcrun swiftc -swift-version 5 -parse-as-library scripts/MenuFixture.swift -o artifacts/menu-recovery/probe-fixture
printf '%s\n' 'Built artifacts/menu-recovery/probe-executable and probe-fixture (not launched)'
