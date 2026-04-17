#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
swiftc Axol.swift -framework Cocoa -o axol
echo "Built ./axol — run it with: ./axol"
