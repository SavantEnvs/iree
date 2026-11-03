#!/usr/bin/env bash
#
# mayhem/test.sh — RUN IREE's own runtime gtest binaries (listed in mayhem/gtests.txt, built by
# mayhem/build.sh into build-tests/). exit 0 = pass.
#
# Each gtest binary is executed directly from bash and its own summary lines are parsed, so a neutered
# (or empty-output) binary yields no "[  PASSED  ] N tests" line and counts as a failure — no ctest.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}


# Lower bound on executed cases so a silently truncated/neutered suite cannot pass.
MIN_CASES=${MIN_CASES:-1500}

passed=0 failed=0 skipped=0
while read -r path; do
  case "$path" in ''|'#'*) continue ;; esac
  bin="$SRC/build-tests/$path"
  if [ ! -x "$bin" ]; then echo "FAIL: missing test binary $bin"; failed=$((failed+1)); continue; fi
  out=$(cd "$SRC/build-tests" && timeout 600 "$bin" --gtest_color=no 2>&1); rc=$?
  ran=$(printf '%s\n' "$out" | sed -nE 's/^\[==========\] ([0-9]+) tests? from .* ran\..*/\1/p' | tail -1)
  ok=$(printf '%s\n' "$out" | sed -nE 's/^\[  PASSED  \] ([0-9]+) tests?\./\1/p' | tail -1)
  skp=$(printf '%s\n' "$out" | sed -nE 's/^\[  SKIPPED \] ([0-9]+) tests?, listed below:/\1/p' | tail -1)
  bad=$(printf '%s\n' "$out" | sed -nE 's/^\[  FAILED  \] ([0-9]+) tests?, listed below:/\1/p' | tail -1)
  ran=${ran:-0}; ok=${ok:-0}; skp=${skp:-0}; bad=${bad:-0}
  if [ "$rc" -ne 0 ] || [ "$ran" -eq 0 ] || [ "$bad" -ne 0 ] || [ $((ok + skp)) -ne "$ran" ]; then
    echo "FAIL: $path (rc=$rc ran=$ran passed=$ok skipped=$skp failed=$bad)"
    printf '%s\n' "$out" | tail -25
    failed=$((failed + (bad > 0 ? bad : 1)))
    passed=$((passed + ok)); skipped=$((skipped + skp))
    continue
  fi
  echo "ok: $path ($ok passed, $skp skipped)"
  passed=$((passed + ok)); skipped=$((skipped + skp))
done < "$SRC/mayhem/gtests.txt"

if [ "$passed" -lt "$MIN_CASES" ]; then
  echo "FAIL: only $passed gtest cases passed (expected >= $MIN_CASES)"
  failed=$((failed+1))
fi

emit_ctrf "gtest" "$passed" "$failed" "$skipped"
