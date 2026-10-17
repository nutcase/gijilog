#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/checks
target_arch="$(uname -m)"
swiftc -swift-version 5 -parse-as-library -target "$target_arch-apple-macosx15.0" \
  Sources/Gijilog/Models.swift Sources/Gijilog/Recorder.swift Sources/Gijilog/Processing.swift \
  Sources/Gijilog/MinutesEngine.swift Sources/Gijilog/Pipeline.swift Sources/Gijilog/Store.swift \
  Sources/Gijilog/MCPServer.swift Sources/Gijilog/Corrections.swift Sources/Gijilog/Agent.swift Sources/Gijilog/Sync.swift \
  Sources/Gijilog/StoreRecovery.swift Sources/Gijilog/StoreRecording.swift Sources/Gijilog/StoreProcessing.swift \
  Sources/Gijilog/StoreTags.swift Sources/Gijilog/StoreEditing.swift Sources/Gijilog/StoreMCP.swift Sources/Gijilog/StoreAsk.swift \
  Tests/GijilogTests/*.swift -o .build/checks/processing-tests
.build/checks/processing-tests
