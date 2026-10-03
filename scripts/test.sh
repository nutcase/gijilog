#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/checks
target_arch="$(uname -m)"
swiftc -swift-version 5 -parse-as-library -target "$target_arch-apple-macosx15.0" \
  Sources/Minutes/Models.swift Sources/Minutes/Recorder.swift Sources/Minutes/Processing.swift \
  Sources/Minutes/MinutesEngine.swift Sources/Minutes/Pipeline.swift Sources/Minutes/Store.swift \
  Tests/MinutesTests/*.swift -o .build/checks/processing-tests
.build/checks/processing-tests
