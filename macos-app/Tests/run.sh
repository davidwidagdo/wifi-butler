#!/usr/bin/env bash
# Compiles the pure-logic units + tests into a standalone executable and runs it.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."   # -> macos-app/
OUT="$(mktemp -d)/tests"
swiftc -o "$OUT" \
  Sources/ByteFormatter.swift \
  Sources/SpeedMath.swift \
  Sources/UsageStore.swift \
  Sources/CPUMath.swift \
  Sources/MemoryMath.swift \
  Sources/ProcessMath.swift \
  Sources/DiskMath.swift \
  Sources/SystemFormat.swift \
  Sources/LoginForm.swift \
  Tests/TestSupport.swift \
  Tests/ByteFormatterTests.swift \
  Tests/SpeedMathTests.swift \
  Tests/UsageStoreTests.swift \
  Tests/CPUMathTests.swift \
  Tests/MemoryMathTests.swift \
  Tests/ProcessMathTests.swift \
  Tests/SystemFormatTests.swift \
  Tests/LoginFormTests.swift \
  Tests/main.swift
"$OUT"
