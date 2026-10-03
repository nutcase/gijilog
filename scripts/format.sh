#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

if ! xcrun --find swift-format >/dev/null 2>&1; then
  print -u2 'swift-format が必要です。Swift 6以降のCommand Line Toolsを用意してください。'
  exit 1
fi

xcrun swift-format format --configuration .swift-format --recursive --in-place Sources Tests Package.swift
print '整形が完了しました。./scripts/check.sh で検証してください。'
