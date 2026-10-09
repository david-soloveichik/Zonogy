// Exercises pattern validation with synthetic bytes; never injects into or changes the real Dock.
#define INSTANTMINIMIZE_TEST
#include "payload.m"
#include <assert.h>

@interface DockBar : NSObject
- (float)effectDur;
@end
@implementation DockBar
- (float)effectDur { return 0.5f; }
@end

int main(void) {
    @autoreleasepool {
        uint8_t bytes[4096] = {0}, before[4096];
        size_t offset = 0;
        for (int i = 0; i < g_pattern_count; i++) {
            uint8_t pattern[128], mask[128];
            size_t length = parse_pattern(g_patterns[i].pattern, pattern, mask, sizeof(pattern));
            assert(length > 0 && (length & 3) == 0);
            for (int site = 0; site < 2; site++) {
                memcpy(bytes + offset, pattern, length);
                offset += length + 16;
            }
        }
        memcpy(before, bytes, sizeof(bytes));
        assert(preflight_patterns((uint64_t)bytes, sizeof(bytes)));
        assert(!memcmp(bytes, before, sizeof(bytes)));
        // Missing the unminimize match for any one effect must reject the whole patch.
        for (int i = 0; i < g_pattern_count; i++) {
            uint8_t pattern[128], mask[128];
            size_t length = parse_pattern(g_patterns[i].pattern, pattern, mask, sizeof(pattern));
            size_t match = find_pattern(bytes, sizeof(bytes), pattern, mask, length, 0);
            assert(match != SIZE_MAX);
            bytes[match] ^= 0xff;
            assert(!preflight_patterns((uint64_t)bytes, sizeof(bytes)));
            bytes[match] ^= 0xff;
        }
        assert(find_pattern(bytes, 1, bytes, bytes, 2, 0) == SIZE_MAX);
        assert(find_pattern(bytes, sizeof(bytes), bytes, bytes, 0, 0) == SIZE_MAX);
        puts("InstantMinimize native tests: all tests passed");
        return 0;
    }
}
