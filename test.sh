#!/bin/sh
set -eu
cd "$(dirname "$0")"
mkdir -p build
swiftc -swift-version 5 -D TESTING \
  Sources/main.swift Tests/SamplerTests.swift -o build/SamplerTests
build/SamplerTests
