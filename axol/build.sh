#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# -O optimizes, -wmo enables whole-module optimization so dead code (unused
# adapter fields, etc.) gets dropped. `strip` drops debug symbols and local
# strings — shaves the binary from ~750 KB to ~300 KB without affecting
# runtime behavior. Skip with NO_STRIP=1 when debugging a crash.
#
# Source organization: Axol.swift holds the UI layer and the app delegate.
# Everything else lives in domain-scoped files — see the top of Axol.swift
# for the map. All files compile into one module so internal-level
# references don't need `public`.
SOURCES=(
    Scheduled.swift
    Server.swift
    Adapters.swift
    Envelope.swift
    AlertStore.swift
    Themes.swift
    Axol.swift
    main.swift
)

swiftc -O -wmo "${SOURCES[@]}" -framework Cocoa -o axol

if [[ "${NO_STRIP:-0}" != "1" ]]; then
    strip -x axol
fi

size=$(ls -l axol | awk '{printf "%.0f KB", $5/1024}')
echo "Built ./axol ($size) — run it with: ./axol"
