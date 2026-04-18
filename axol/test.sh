#!/usr/bin/env bash
# Compiles a test binary that links the same library files as the main
# app (minus Axol.swift / main.swift / Server.swift — those pull in Cocoa
# and an app entry point). Runs the binary and exits non-zero on any
# failed assertion.
#
# The test binary is rebuilt from scratch on each run; no XCTest or
# external deps. Keeps tooling aligned with `build.sh` — "just swiftc".

set -euo pipefail
cd "$(dirname "$0")"

# Library sources the tests can exercise directly. Excludes anything that
# depends on Cocoa/AppKit (covered by integration testing via curl + the
# running app, not unit tests).
LIB_SOURCES=(
    Adapters.swift
    Themes.swift
)
TEST_SOURCES=(
    tests/main.swift
)

OUT=".axol-tests"
swiftc -O "${LIB_SOURCES[@]}" "${TEST_SOURCES[@]}" -o "$OUT"

./"$OUT"
status=$?
rm -f "$OUT"
exit $status
