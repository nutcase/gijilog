#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/checks
target_arch="$(uname -m)"
swiftc -swift-version 5 -parse-as-library -target "$target_arch-apple-macosx15.0" \
  Sources/Gijilog/Models.swift Sources/Gijilog/Recorder.swift Sources/Gijilog/Processing.swift \
  Sources/Gijilog/MinutesEngine.swift Sources/Gijilog/Pipeline.swift Sources/Gijilog/Store.swift \
  Tests/GijilogTests/*.swift -o .build/checks/processing-tests
.build/checks/processing-tests
