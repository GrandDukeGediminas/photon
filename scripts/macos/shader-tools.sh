#!/bin/sh
# Builds glslangValidator and spirv-cross as static universal (arm64 + x86_64) binaries for photon.app's
# Contents/Helpers: scripts/macos/shader-tools.sh <output dir> [work dir]
# Same versions as the Flatpak (packaging/flatpak/io.github.photon2.Photon.yml). Needs git, cmake and ninja.
set -e
out=$(mkdir -p "$1" && cd "$1" && pwd)
work=${2:-$(mktemp -d)}
mkdir -p "$work"
cd "$work"
common="-G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64;x86_64 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DBUILD_SHARED_LIBS=OFF"

[ -d glslang ] || git clone -q --depth 1 --branch 14.3.0 https://github.com/KhronosGroup/glslang.git
cmake -S glslang -B glslang/build $common -DENABLE_OPT=OFF -DGLSLANG_TESTS=OFF -DENABLE_GLSLANG_BINARIES=ON > glslang.log
cmake --build glslang/build --target glslang-standalone >> glslang.log
cp glslang/build/StandAlone/glslang "$out/glslangValidator"

[ -d SPIRV-Cross ] || git clone -q --depth 1 --branch vulkan-sdk-1.3.290.0 https://github.com/KhronosGroup/SPIRV-Cross.git
cmake -S SPIRV-Cross -B SPIRV-Cross/build $common -DSPIRV_CROSS_ENABLE_TESTS=OFF -DSPIRV_CROSS_SHARED=OFF > spirv-cross.log
cmake --build SPIRV-Cross/build --target spirv-cross >> spirv-cross.log
cp SPIRV-Cross/build/spirv-cross "$out/spirv-cross"

for t in glslangValidator spirv-cross; do
  lipo -info "$out/$t"
  # Only system libraries: the app must run without Homebrew.
  if otool -L "$out/$t" | grep -E '^[[:space:]]+/' | grep -v -E '^[[:space:]]+(/usr/lib/|/System/)'; then
    echo "$t links non-system libraries"; exit 1
  fi
done
