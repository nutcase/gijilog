#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/lint.sh

print '[3/4] 回帰テスト'
./scripts/test.sh

print '[4/4] リリースビルド'
swift build --build-system native -c release

print 'すべてのチェックに成功しました。'
