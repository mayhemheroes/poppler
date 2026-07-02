#!/usr/bin/env bash
#
# poppler/mayhem/test.sh — golden PDF-PARSE oracle + CTRF summary. exit 0 iff the oracle passes.
#
# PATH CHOSEN: a self-contained GOLDEN oracle over the fuzzed parse path (NOT poppler's full ctest
# regression suite, which needs the external poppler-test-data repo). mayhem/oracle/pdf_oracle.cc
# drives the exact poppler::document::load_from_file / load_from_raw_data API the cpp/ fuzzers hit
# (PDFDoc -> XRef -> Lexer -> Parser) over a known minimal %PDF (mayhem/oracle/golden.pdf) and asserts
# byte-derived facts: loads, not locked, exactly 1 page, MediaBox 612x792, AND that garbage is
# rejected. It links the SAME instrumented libpoppler.a / libpoppler-cpp.a that build.sh produced, so
# the oracle exercises real parser code. A no-op / "always succeed" patch cannot pass (check 5), nor
# can a patch that breaks parsing or page geometry (checks 1-4).
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
: "${CXX:=clang++}"
SRCDIR="${SRC:-/mayhem}"
cd "$SRCDIR"

BUILD="$SRCDIR/mayhem-build"
ORACLE_SRC="$SRCDIR/mayhem/oracle/pdf_oracle.cc"
GOLDEN="$SRCDIR/mayhem/oracle/golden.pdf"

# emit_ctrf <tool> <passed> <failed> [skipped]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}"
  local tests=$(( passed + failed + skipped ))
  cat > "${CTRF_REPORT:-$SRCDIR/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": { "tests": $tests, "passed": $passed, "failed": $failed, "pending": 0, "skipped": $skipped, "other": 0 }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":0,"skipped":%d,"other":0}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$skipped"
  [ "$failed" -eq 0 ]
}

if [ ! -f "$BUILD/libpoppler.a" ] || [ ! -f "$BUILD/cpp/libpoppler-cpp.a" ]; then
  echo "missing $BUILD libs — run mayhem/build.sh first" >&2
  emit_ctrf "poppler-oracle" 0 1 0; exit 2
fi
[ -f "$ORACLE_SRC" ] || { echo "missing $ORACLE_SRC" >&2; emit_ctrf "poppler-oracle" 0 1 0; exit 2; }
[ -f "$GOLDEN" ]     || { echo "missing $GOLDEN" >&2;     emit_ctrf "poppler-oracle" 0 1 0; exit 2; }

DEPS="freetype2 lcms2 libopenjp2 fontconfig libpng libtiff-4"
BUILD_CFLAGS="$(pkg-config --cflags $DEPS)"
BUILD_LDFLAGS="$(pkg-config --libs $DEPS) -ljpeg -lz -ldl -lm -lpthread"

# Same narrow benign-UB relax as build.sh (signed shift / enum range in the tokeniser) so the oracle
# binary matches the harnesses; ASan + the rest of UBSan stay halting.
SAN_BUILD="$SANITIZER_FLAGS"
case "$SANITIZER_FLAGS" in *undefined*) SAN_BUILD="$SANITIZER_FLAGS -fno-sanitize=shift-base -fno-sanitize=enum" ;; esac

ORACLE_BIN="$BUILD/pdf_oracle"
echo "=== compiling golden oracle ==="
if ! $CXX $SAN_BUILD -std=c++23 -I"$SRCDIR/cpp" -I"$BUILD/cpp" $BUILD_CFLAGS \
      "$ORACLE_SRC" \
      "$BUILD/cpp/libpoppler-cpp.a" "$BUILD/libpoppler.a" $BUILD_LDFLAGS \
      -o "$ORACLE_BIN" 2>/tmp/oracle-build.log; then
  echo "oracle failed to compile/link:" >&2; tail -20 /tmp/oracle-build.log >&2
  emit_ctrf "poppler-oracle" 0 1 0; exit 1
fi

echo "=== running golden oracle ==="
out="$("$ORACLE_BIN" "$GOLDEN" 2>&1)"; rc=$?
echo "$out"

# Each "  ok  " line is a passed check; each "  FAIL" line a failed one.
PASSED=$(printf '%s\n' "$out" | grep -c '^  ok ' || true)
FAILED=$(printf '%s\n' "$out" | grep -c '^  FAIL' || true)
: "${PASSED:=0}" "${FAILED:=0}"

# If the binary aborted (sanitizer/assert) before printing, the parsed counts may be empty/zero —
# fall back to the exit code as the verdict.
if [ "$(( PASSED + FAILED ))" -eq 0 ]; then
  [ "$rc" -eq 0 ] && { emit_ctrf "poppler-oracle" 1 0 0; exit 0; }
  emit_ctrf "poppler-oracle" 0 1 0; exit 1
fi
[ "$rc" -ne 0 ] && [ "$FAILED" -eq 0 ] && FAILED=1   # nonzero exit with no parsed FAIL -> count one

emit_ctrf "poppler-oracle" "$PASSED" "$FAILED" 0
