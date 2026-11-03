#!/usr/bin/env bash
#
# mayhem/build.sh — builds IREE's runtime-only libFuzzer harnesses (sanitized, one binary per target in
# mayhem/targets.txt, plus a -standalone reproducer each) and the normal-flags gtest binaries that
# mayhem/test.sh runs. The compiler (IREE_BUILD_COMPILER=OFF) and its LLVM submodule are NOT built.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${SRC:=/mayhem}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# Only the runtime submodules are needed; llvm-project, torch-mlir, stablehlo etc. are huge and unused.
# They are fetched once (image build has network) and survive `git clean -ffdX` and offline re-runs.
for sm in flatcc googletest benchmark hip-build-deps hsa-runtime-headers; do
  d="third_party/$sm"
  if [ -z "$(ls -A "$d" 2>/dev/null)" ]; then
    git submodule update --init --depth 1 -- "$d" || git submodule update --init -- "$d"
  fi
done

COMMON_CMAKE=(
  -G Ninja -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX"
  -DIREE_BUILD_COMPILER=OFF -DIREE_BUILD_TESTS=ON -DIREE_BUILD_SAMPLES=OFF
  -DIREE_HAL_DRIVER_VULKAN=OFF -DIREE_HAL_DRIVER_AMDGPU=ON
  -DIREE_ENABLE_RUNTIME_TRACING=OFF
  # libbacktrace is FetchContent-downloaded; the build must be air-gapped.
  -DIREE_ENABLE_LIBBACKTRACE=OFF
  -DIREE_ERROR_ON_MISSING_SUBMODULES=OFF
)

# CMake drops command-line -D options when it wipes a cache whose compiler path changed (the cache-prefill
# masquerade dir vs. plain `clang`), so every run configures from scratch; a full rebuild takes minutes.
rm -rf build-fuzz build-tests

# 1) Sanitized fuzz build. LeakSanitizer is off at build time via mayhem/lsan_off.cc, linked into every
#    executable of this tree (fuzz binaries and, through the link lines reused below, the standalone ones).
mkdir -p build-fuzz
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$SRC/build-fuzz/lsan_off.o"
# -fno-sanitize=alignment: special_tokens.c stores uint32_t into a packed slab at a misaligned address
# during the harness's one-time initialization, which would halt every run before the first input.
# Benign on the supported targets; ASan and every other UBSan check stay on and halting.
RELAX="-fno-sanitize=alignment"
FUZZ_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS $RELAX -fsanitize=fuzzer-no-link"
cmake -B build-fuzz "${COMMON_CMAKE[@]}" -DIREE_ENABLE_FUZZING=ON \
  -DCMAKE_C_FLAGS="$FUZZ_FLAGS" -DCMAKE_CXX_FLAGS="$FUZZ_FLAGS" \
  -DCMAKE_C_FLAGS_RELEASE="-O1 -DNDEBUG" -DCMAKE_CXX_FLAGS_RELEASE="-O1 -DNDEBUG" \
  -DCMAKE_EXE_LINKER_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS $RELAX $SRC/build-fuzz/lsan_off.o"
mapfile -t FUZZ_LINES < <(grep -vE '^\s*(#|$)' mayhem/targets.txt)
ninja -C build-fuzz -j"$MAYHEM_JOBS" $(printf '%s\n' "${FUZZ_LINES[@]}" | awk '{print $2}')

# 2) Standalone (run-once, no libFuzzer runtime) reproducer per harness: replay each fuzz binary's own
#    link line with the standalone driver (compiled as C) in place of -fsanitize=fuzzer.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$SRC/build-fuzz/standalone_main.o"
for line in "${FUZZ_LINES[@]}"; do
  name=${line%% *}; path=${line##* }
  cp "build-fuzz/$path" "$SRC/$name"
  cmd=$(ninja -C build-fuzz -t commands "$path" | tail -1)
  cmd=${cmd#: && }; cmd=${cmd% && :}
  cmd=${cmd// -fsanitize=fuzzer / $SRC/build-fuzz/standalone_main.o }
  cmd=$(printf '%s' "$cmd" | sed -E "s# -o [^ ]+ # -o $SRC/$name-standalone #")
  (cd build-fuzz && eval "$cmd")
done

# 3) Test suite with the project's normal flags (no sanitizers, no fuzzing) — a clean, independent build.
mkdir -p build-tests
cmake -B build-tests "${COMMON_CMAKE[@]}" -DIREE_ENABLE_FUZZING=OFF \
  -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS" \
  -DCMAKE_EXE_LINKER_FLAGS="$COVERAGE_FLAGS"
mapfile -t TEST_PATHS < <(grep -vE '^\s*(#|$)' mayhem/gtests.txt)
ninja -C build-tests -j"$MAYHEM_JOBS" "${TEST_PATHS[@]}"
