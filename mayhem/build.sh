#!/usr/bin/env bash
#
# poppler/mayhem/build.sh — build poppler's OSS-Fuzz cpp/ PDF-parsing harnesses as sanitized
# libFuzzer targets (+ standalone reproducers).
#
# Fuzzed surface: poppler's CORE PDF parser. Every cpp/ harness feeds attacker-controlled bytes to
# poppler::document::load_from_raw_data() / load_from_file() (-> PDFDoc / XRef / Lexer / Parser /
# Stream filters) and then exercises page rendering, text extraction, metadata, fonts, destinations
# and labels. The instrumented code is the poppler core library itself (libpoppler.a + the C++
# frontend libpoppler-cpp.a), both compiled WITH $SANITIZER_FLAGS.
#
# SCOPE: only the cpp/ fuzzers. poppler's OSS-Fuzz build also ships glib/ and qt6/ fuzzers, but those
# pull in cairo + pango + glib + a full static Qt6 (all built from source in OSS-Fuzz) which is not
# tractable on the org base image. The cpp/ fuzzers cover the same core PDF parser on the same
# load_from_raw_data() entry point; the glib/qt6 ones only add frontend-binding surface. Core deps
# (freetype, fontconfig, lcms2, openjpeg) come from light Debian -dev packages, installed by the
# Dockerfile; the fuzzed poppler code stays fully sanitized.
#
# Build contract from the org base ENV: CC/CXX/SANITIZER_FLAGS/LIB_FUZZING_ENGINE/SRC/
# STANDALONE_FUZZ_MAIN/OUT.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
# DEBUG_FLAGS: force DWARF-3 so Mayhem's triage can read debug info (clang-19 defaults to DWARF-5).
# Placed AFTER $SANITIZER_FLAGS so it overrides any -g already in SANITIZER_FLAGS.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
export DEBUG_FLAGS
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${OUT:=/mayhem}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

SRCDIR="${SRC:-/mayhem}"
cd "$SRCDIR"

# poppler narrow benign-UB relax: the PDF tokenizer/colour code performs intentional signed-shift and
# enum-range patterns that UBSan flags on nearly EVERY input (they are not memory-safety bugs and would
# otherwise mask real findings). Disable ONLY those two narrow UBSan sub-checks; ASan (the
# memory-safety oracle) and the rest of UBSan stay halting.
UB_RELAX="-fno-sanitize=shift-base -fno-sanitize=enum"
case "$SANITIZER_FLAGS" in
  *undefined*) SAN_BUILD="$SANITIZER_FLAGS $UB_RELAX $DEBUG_FLAGS" ;;
  *)           SAN_BUILD="$SANITIZER_FLAGS $DEBUG_FLAGS" ;;
esac

# ── 1) Configure + build poppler CORE + the C++ frontend, instrumented, as static libs ────────────
# Use the "Unix Makefiles" generator (NOT Ninja): poppler's CMake emits C++20-module dependency
# scanning that requires clang-scan-deps under Ninja (absent on the base); the Makefiles generator
# does not. Image-OUTPUT backends (png/jpeg/tiff/zlib) and all GUI frontends (glib/qt/cairo) are
# disabled exactly as OSS-Fuzz does — they are not part of the fuzzed PDF-PARSE path.
BUILD="$SRCDIR/mayhem-build"
rm -rf "$BUILD"; mkdir -p "$BUILD"
( cd "$BUILD"
  CFLAGS="$SAN_BUILD" CXXFLAGS="$SAN_BUILD" cmake "$SRCDIR" \
    -DCMAKE_BUILD_TYPE=debug \
    -DBUILD_SHARED_LIBS=OFF \
    -DENABLE_FUZZER=OFF \
    -DFONT_CONFIGURATION=fontconfig \
    -DENABLE_GOBJECT_INTROSPECTION=OFF \
    -DENABLE_GLIB=OFF \
    -DENABLE_QT5=OFF -DENABLE_QT6=OFF \
    -DENABLE_LIBCURL=OFF -DENABLE_GPGME=OFF \
    -DENABLE_UTILS=OFF -DENABLE_CPP=ON \
    -DWITH_Cairo=OFF -DENABLE_NSS3=OFF -DENABLE_BOOST=OFF \
    -DENABLE_LIBPNG=OFF -DENABLE_ZLIB=OFF -DENABLE_LIBTIFF=OFF -DENABLE_LIBJPEG=OFF \
    -DBUILD_CPP_TESTS=OFF -DBUILD_GTK_TESTS=OFF -DBUILD_QT5_TESTS=OFF -DBUILD_QT6_TESTS=OFF \
    -DCMAKE_CXX_FLAGS="$SAN_BUILD" -DCMAKE_C_FLAGS="$SAN_BUILD"
  make poppler poppler-cpp -j"$MAYHEM_JOBS"
)
LIBPOPPLER="$BUILD/libpoppler.a"
LIBPOPPLERCPP="$BUILD/cpp/libpoppler-cpp.a"
[ -f "$LIBPOPPLER" ] && [ -f "$LIBPOPPLERCPP" ] || { echo "poppler static libs not built" >&2; exit 1; }

# ── 2) Link flags for the harnesses ───────────────────────────────────────────────────────────────
# poppler core still references libpng/libtiff/libjpeg/zlib symbols from its always-compiled image &
# flate code paths even with the ENABLE_* backends off, so the system libs must be on the link line.
# -include limits patches a missing <limits> include in OSS-Fuzz's vendored FuzzedDataProvider.h.
DEPS="freetype2 lcms2 libopenjp2 fontconfig libpng libtiff-4"
BUILD_CFLAGS="$(pkg-config --cflags $DEPS)"
BUILD_LDFLAGS="$(pkg-config --libs $DEPS) -ljpeg -lz -ldl -lm -lpthread"

HARNESS_DIR="$SRCDIR/cpp/tests/fuzzing"
INCS="-I$SRCDIR/cpp -I$BUILD/cpp"

# Compile the org standalone run-once driver as an object (no libFuzzer runtime; reads one input).
STANDALONE_OBJ="$BUILD/standalone_main.o"
$CC $SAN_BUILD -c "$STANDALONE_FUZZ_MAIN" -o "$STANDALONE_OBJ"

mkdir -p "$OUT"

# ── 3) Build each cpp/ harness twice: libFuzzer target (-> $OUT/<name>) + standalone reproducer ────
for harness in pdf_fuzzer pdf_file_fuzzer page_label_fuzzer page_search_fuzzer doc_fuzzer; do
  src="$HARNESS_DIR/$harness.cc"
  [ -f "$src" ] || { echo "missing harness $src — skipping" >&2; continue; }

  # libFuzzer target
  $CXX $SAN_BUILD -std=c++23 -include limits $INCS $BUILD_CFLAGS \
      "$src" $LIB_FUZZING_ENGINE \
      "$LIBPOPPLERCPP" "$LIBPOPPLER" $BUILD_LDFLAGS \
      -o "$OUT/$harness"

  # standalone reproducer (org StandaloneFuzzTargetMain.c, no libFuzzer runtime)
  $CXX $SAN_BUILD -std=c++23 -include limits $INCS $BUILD_CFLAGS \
      "$src" "$STANDALONE_OBJ" \
      "$LIBPOPPLERCPP" "$LIBPOPPLER" $BUILD_LDFLAGS \
      -o "$OUT/$harness-standalone"

  echo "built $harness (+ standalone)"
done

echo "build.sh complete:"
ls -la "$OUT"/pdf_fuzzer "$OUT"/pdf_file_fuzzer "$OUT"/page_label_fuzzer \
       "$OUT"/page_search_fuzzer "$OUT"/doc_fuzzer 2>&1 || true
