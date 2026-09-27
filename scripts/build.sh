#!/bin/sh
# Phase 0 verification: clean build of the Kyoku macOS target.
set -e
cd "$(dirname "$0")"
xcodebuild -project Kyoku.xcodeproj -scheme Kyoku -configuration Debug build
