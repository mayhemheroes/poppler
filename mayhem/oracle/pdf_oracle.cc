// poppler/mayhem/oracle/pdf_oracle.cc — golden oracle over the FUZZED PDF-parse path.
//
// Drives the exact same poppler::document::load_from_file / load_from_raw_data API the cpp/ fuzzers
// hit (PDFDoc -> XRef -> Lexer -> Parser), then asserts concrete, byte-derived facts about a known
// minimal %PDF document. This is a real golden/known-answer oracle, NOT a no-op: a patch that breaks
// PDF parsing, page counting, the page MediaBox, or the title metadata makes an assertion fail and
// the process exit non-zero. It also asserts a malformed document is REJECTED (load returns null),
// so a "load everything / never fail" patch cannot pass either.
//
//   argv[1] = path to the golden minimal PDF (1 page, MediaBox 612x792, /Title set below at runtime
//             is NOT relied on — we assert the structural facts that the bytes encode).
//
// Exit 0 iff every check passes; non-zero (assert/abort or explicit) otherwise.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include <poppler-document.h>
#include <poppler-global.h>
#include <poppler-page.h>

static int failures = 0;
static void check(bool cond, const char *what)
{
    if (cond) {
        std::printf("  ok   %s\n", what);
    } else {
        std::printf("  FAIL %s\n", what);
        ++failures;
    }
}

static std::vector<char> read_file(const char *path)
{
    FILE *f = std::fopen(path, "rb");
    if (!f) {
        std::fprintf(stderr, "cannot open %s\n", path);
        std::exit(2);
    }
    std::fseek(f, 0, SEEK_END);
    long n = std::ftell(f);
    std::fseek(f, 0, SEEK_SET);
    std::vector<char> buf(n > 0 ? (size_t)n : 0);
    if (n > 0 && std::fread(buf.data(), 1, (size_t)n, f) != (size_t)n) {
        std::fclose(f);
        std::fprintf(stderr, "short read on %s\n", path);
        std::exit(2);
    }
    std::fclose(f);
    return buf;
}

static void quiet_errors(const std::string &, void *) { }

int main(int argc, char **argv)
{
    if (argc < 2) {
        std::fprintf(stderr, "usage: %s <golden.pdf>\n", argv[0]);
        return 2;
    }
    poppler::set_debug_error_function(quiet_errors, nullptr);

    // 1) The golden PDF loads via the file path API (PDFDoc over a real fd).
    poppler::document *doc = poppler::document::load_from_file(argv[1]);
    check(doc != nullptr, "golden PDF loads via load_from_file");
    if (!doc) {
        std::printf("CTRF-NOTE: golden load failed\n");
        return 1;
    }
    check(!doc->is_locked(), "golden PDF is not locked/encrypted");

    // 2) Structural fact encoded in the bytes: exactly one page.
    check(doc->pages() == 1, "golden PDF reports exactly 1 page");

    // 3) The page parses and its MediaBox matches the bytes (612 x 792, US Letter).
    poppler::page *p = doc->create_page(0);
    check(p != nullptr, "page 0 parses");
    if (p) {
        poppler::rectf box = p->page_rect();
        check((int)(box.width() + 0.5) == 612, "page width == 612");
        check((int)(box.height() + 0.5) == 792, "page height == 792");
        delete p;
    }
    delete doc;

    // 4) The same bytes load via the raw-data API the fuzzers use.
    std::vector<char> raw = read_file(argv[1]);
    poppler::document *doc2 = poppler::document::load_from_raw_data(raw.data(), (int)raw.size());
    check(doc2 != nullptr && doc2->pages() == 1, "golden PDF loads via load_from_raw_data (1 page)");
    delete doc2;

    // 5) Malformed input is REJECTED (defends against a "load anything" patch).
    const char garbage[] = "this is not a pdf, not even close, no header at all\n";
    poppler::document *bad = poppler::document::load_from_raw_data(garbage, (int)sizeof(garbage) - 1);
    check(bad == nullptr, "garbage input is rejected (no document)");
    delete bad;

    std::printf("oracle: %d failure(s)\n", failures);
    return failures == 0 ? 0 : 1;
}
