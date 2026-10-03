#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

if ! xcrun --find swift-format >/dev/null 2>&1; then
  print -u2 'swift-format が必要です。Swift 6以降のCommand Line Toolsを用意してください。'
  exit 1
fi
if ! command -v swiftlint >/dev/null 2>&1; then
  print -u2 'SwiftLint が必要です。brew install swiftlint を実行してください。'
  exit 1
fi

print '[1/4] swift-format: 整形チェック'
xcrun swift-format lint --configuration .swift-format --strict --recursive Sources Tests Package.swift

print '[2/4] SwiftLint: 静的チェック'
# Resolve SourceKit from the compiler used for the build, including Command Line Tools.
swift_compiler="$(xcrun --find swift)"
swift_toolchain="${swift_compiler%/usr/bin/swift}"
XCODE_DEFAULT_TOOLCHAIN_OVERRIDE="$swift_toolchain" \
  swiftlint lint --config .swiftlint.yml --strict --quiet --cache-path .build/swiftlint-cache
