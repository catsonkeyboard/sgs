#!/bin/bash
# Verify that bundled third-party media still match the reviewed byte manifest.
set -e

cd "$(dirname "$0")/.."

if ! command -v shasum >/dev/null 2>&1; then
  echo "找不到 shasum，无法校验素材" >&2
  exit 1
fi

expected_count=$(wc -l < THIRD_PARTY_ASSETS.sha256 | tr -d ' ')
actual_count=$(find assets -type f ! -path 'assets/README.md' | wc -l | tr -d ' ')
if [ "$actual_count" != "$expected_count" ]; then
  echo "素材文件数量变化：清单 $expected_count，当前 $actual_count" >&2
  echo "请核对授权并同步 THIRD_PARTY_ASSETS.sha256 与归属说明" >&2
  exit 1
fi

exec shasum -a 256 -c THIRD_PARTY_ASSETS.sha256
