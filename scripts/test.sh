#!/bin/bash
set -euo pipefail
task_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$task_root"
mkdir -p .build/clang-cache .build/swift-cache .build/package-cache
export CLANG_MODULE_CACHE_PATH="$task_root/.build/clang-cache"
export SWIFT_MODULECACHE_PATH="$task_root/.build/swift-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$task_root/.build/package-cache"
compiler_path=$(xcrun --find swiftc)
macro_library="$(dirname "$compiler_path")/../lib/swift/host/plugins/testing/libTestingMacros.dylib"
test_flags=(--disable-sandbox --cache-path "$task_root/.build/package-cache")
# CLT SwiftPM can omit the Swift Testing macro load directive. Full Xcode may
# already provide it; explicitly loading the shipped library is harmless.
if [[ -f "$macro_library" ]]; then
  test_flags+=(-Xswiftc -load-plugin-library -Xswiftc "$macro_library")
fi
swift test "${test_flags[@]}" "$@"
