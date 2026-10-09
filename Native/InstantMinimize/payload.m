// instantmini payload - removes Dock minimize/unminimize animations in-process
//
// Injected into Dock via LLDB or the Mach loader. Patches ARM64 instructions to
// zero minimize/unminimize duration values while preserving Dock's control flow.

#import <Cocoa/Cocoa.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <objc/runtime.h>
#import <libkern/OSCacheControl.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <limits.h>
#include <math.h>
#include <pthread.h>
#include <os/log.h>
#include "status.h"

// ============================================================================
#pragma mark - Pattern Specification
// ============================================================================

typedef struct {
    const char   *pattern;       // Hex pattern with ?? wildcards
    int           patch_offset;  // Byte offset to instruction to replace
    const char   *name;          // Identifier for logging
    int           min_matches;   // Required sites before reporting full success
} PatternSpec;

// ============================================================================
#pragma mark - Pattern Definitions
// ============================================================================

static PatternSpec g_patterns[] = {
    // Preserve the min/max branches: their animated paths also handle window
    // preparation and transition completion. Only duration values are patched.
    // ========================================================================
    // Minimize-to-app-icon: zero the per-effect animation duration
    // ========================================================================
    // With "Minimize windows into application icon" enabled, the Dock bypasses
    // effectDur and animates in a separate minimize/unminimize function pair.
    // Each effect hardcodes its duration into d8, then moves it into d0
    // (fmov d0, d8 on Sequoia; mov v0.16b, v8.16b on 27) and calls the global
    // animation duration setter. d8 is reused for prepareWindowForMinMax:duration:,
    // so we patch the d8 assignment itself. Each pattern matches twice
    // (minimize + unminimize).
    //
    // Genie: fcsel s0, s0, s1, ne; fcvt d8, s0 (genie-speed pref, default 0.5)
    {
        .pattern       = "00 1C 21 1E 08 C0 22 1E ?? ?? ?? ?? ?? ?? ?? 97",
        .patch_offset  = 4,
        .name          = "minimize-to-app-genie",
        .min_matches   = 2,
    },
    // Scale: fmov d1, #0.25; fcsel d8, d1, d0, ne
    {
        .pattern       = "01 10 6A 1E 28 1C 60 1E ?? ?? ?? ?? ?? ?? ?? 97",
        .patch_offset  = 4,
        .name          = "minimize-to-app-scale",
        .min_matches   = 2,
    },
    // Suck: fmov d1, #4.0; fcsel d8, d0, d1, ne (d0 = 0.4)
    {
        .pattern       = "01 10 62 1E 08 1C 61 1E ?? ?? ?? ?? ?? ?? ?? 97",
        .patch_offset  = 4,
        .name          = "minimize-to-app-suck",
        .min_matches   = 2,
    },
};

static const int g_pattern_count = sizeof(g_patterns) / sizeof(g_patterns[0]);

// ============================================================================
#pragma mark - Global State
// ============================================================================

typedef struct {
    uint64_t addr;
    uint32_t expected;
} PatchRecord;

static PatchRecord g_patches[64];
static int g_patched_count = 0;
static Method g_effect_dur_method = NULL;
typedef void (*PrepareMinMaxIMP)(id, SEL, uint32_t, double);
static PrepareMinMaxIMP g_orig_prepare_min_max = NULL;
static Method g_prepare_min_max_method = NULL;
static pthread_mutex_t g_patch_lock = PTHREAD_MUTEX_INITIALIZER;
static BOOL g_patch_attempted = NO;
static InstantminiStatus g_patch_status = INSTANTMINI_NOT_READY;

// ============================================================================
#pragma mark - Logging
// ============================================================================

static void log_line(const char *fmt, ...) {
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);

    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.dsemeas.zonogy", "InstantMinimizePayload"); });
    os_log_info(log, "%{public}s", buf);
}

// ============================================================================
#pragma mark - ARM64 Instructions
// ============================================================================

// MOVI d_, #0: OR with the destination register number (bits 0-4).
#define ARM64_MOVI_D_ZERO 0x2f00e400u

// MOVI d-register encoding: destination register is in bits 0-4.
static uint32_t get_patch_instruction(uint64_t patch_addr) {
    uint32_t orig = *(volatile uint32_t *)patch_addr;
    return ARM64_MOVI_D_ZERO | (orig & 0x1f);
}

// ============================================================================
#pragma mark - Pattern Matching
// ============================================================================

static int hexval(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return 10 + (c - 'a');
    if (c >= 'A' && c <= 'F') return 10 + (c - 'A');
    return -1;
}

// Parse hex pattern string into bytes and mask arrays
// Returns number of bytes parsed
static size_t parse_pattern(const char *hex, uint8_t *bytes, uint8_t *mask, size_t capacity) {
    size_t n = 0;
    const char *p = hex;

    while (*p && n < capacity) {
        while (*p == ' ') p++;
        if (!*p) break;

        if (p[0] == '?' && p[1] == '?') {
            bytes[n] = 0;
            mask[n] = 0;  // Wildcard - don't compare
            n++;
            p += 2;
        } else {
            int hi = hexval(p[0]);
            int lo = hexval(p[1]);
            if (hi < 0 || lo < 0) break;
            bytes[n] = (uint8_t)((hi << 4) | lo);
            mask[n] = 1;  // Must match
            n++;
            p += 2;
        }
        if (*p == ' ') p++;
    }
    return n;
}

// Search buffer for pattern, respecting mask. Returns offset or SIZE_MAX if not found.
static size_t find_pattern(const uint8_t *buf, size_t buflen,
                           const uint8_t *pattern, const uint8_t *mask, size_t patlen,
                           size_t start_offset) {
    if (!buf || patlen == 0 || buflen < patlen || start_offset > buflen - patlen) {
        return SIZE_MAX;
    }

    size_t limit = buflen - patlen;
    for (size_t i = start_offset; i <= limit; i++) {
        BOOL match = YES;
        for (size_t j = 0; j < patlen; j++) {
            if (mask[j] && buf[i + j] != pattern[j]) {
                match = NO;
                break;
            }
        }
        if (match) return i;
    }
    return SIZE_MAX;
}

// ============================================================================
#pragma mark - Mach-O Parsing
// ============================================================================

// Locate Dock's __TEXT segment in memory
static BOOL find_dock_text(uint64_t *text_start, uint64_t *text_size) {
    uint32_t image_count = _dyld_image_count();

    for (uint32_t i = 0; i < image_count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name || !strstr(name, "/Dock.app/Contents/MacOS/Dock")) continue;

        const struct mach_header_64 *header = (const struct mach_header_64 *)_dyld_get_image_header(i);
        if (!header || header->magic != MH_MAGIC_64) continue;

        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        const uint8_t *cmd_ptr = (const uint8_t *)(header + 1);

        for (uint32_t c = 0; c < header->ncmds; c++) {
            const struct load_command *cmd = (const struct load_command *)cmd_ptr;
            if (cmd->cmd == LC_SEGMENT_64) {
                const struct segment_command_64 *seg = (const struct segment_command_64 *)cmd_ptr;
                if (strcmp(seg->segname, "__TEXT") == 0) {
                    *text_start = seg->vmaddr + (uint64_t)slide;
                    *text_size = seg->vmsize;
                    return YES;
                }
            }
            cmd_ptr += cmd->cmdsize;
        }
    }
    return NO;
}

// ============================================================================
#pragma mark - Memory Patching
// ============================================================================

static inline uint64_t page_start(uint64_t addr) {
    return addr & ~(uint64_t)(vm_page_size - 1);
}

// Make memory page writable for patching
static BOOL make_writable(uint64_t addr) {
    kern_return_t kr = vm_protect(mach_task_self(), page_start(addr), vm_page_size, 0,
                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) {
        log_line("vm_protect RW failed @0x%llx: %d", (unsigned long long)addr, kr);
        return NO;
    }
    return YES;
}

// Restore memory page to executable
static BOOL make_executable(uint64_t addr) {
    kern_return_t kr = vm_protect(mach_task_self(), page_start(addr), vm_page_size, 0,
                                  VM_PROT_READ | VM_PROT_EXECUTE);
    if (kr != KERN_SUCCESS) {
        log_line("vm_protect RX failed @0x%llx: %d", (unsigned long long)addr, kr);
        return NO;
    }
    return YES;
}

// Write instruction and invalidate its instruction cache.
static void write_instruction(uint64_t addr, uint32_t instruction) {
    *(volatile uint32_t *)addr = instruction;
    sys_icache_invalidate((void *)(uintptr_t)addr, sizeof(uint32_t));
}

// ============================================================================
#pragma mark - Patching Engine
// ============================================================================

// Apply patches for a single pattern specification
static int apply_pattern(PatternSpec *spec, uint64_t text_start, uint64_t text_size,
                         BOOL *failed) {
    uint8_t pattern_bytes[128];
    uint8_t pattern_mask[128];
    size_t pattern_len = parse_pattern(spec->pattern, pattern_bytes, pattern_mask, sizeof(pattern_bytes));
    if (pattern_len == 0) {
        log_line("[%s] invalid empty pattern", spec->name);
        *failed = YES;
        return 0;
    }

    int patched = 0;
    size_t search_offset = 0;

    while (1) {
        size_t match = find_pattern((const uint8_t *)(uintptr_t)text_start, (size_t)text_size,
                                    pattern_bytes, pattern_mask, pattern_len, search_offset);
        if (match == SIZE_MAX) break;

        uint64_t patch_addr = text_start + match + spec->patch_offset;
        if (spec->patch_offset < 0 || (patch_addr & 3) != 0 ||
            text_size < sizeof(uint32_t) ||
            match + (size_t)spec->patch_offset > text_size - sizeof(uint32_t)) {
            log_line("[%s] invalid patch address", spec->name);
            *failed = YES;
            break;
        }
        if (g_patched_count >= (int)(sizeof(g_patches) / sizeof(g_patches[0]))) {
            log_line("Patch record capacity exceeded");
            *failed = YES;
            break;
        }
        uint32_t before = *(volatile uint32_t *)patch_addr;
        uint32_t expected = get_patch_instruction(patch_addr);
        if (expected == before) {
            log_line("[%s] instruction was not replaced: 0x%08x", spec->name, before);
            *failed = YES;
            break;
        }

        if (!make_writable(patch_addr)) {
            *failed = YES;
            break;
        }

        write_instruction(patch_addr, expected);
        if (!make_executable(patch_addr)) {
            *failed = YES;
            break;
        }

        uint32_t after = *(volatile uint32_t *)patch_addr;
        if (after != expected) {
            log_line("[%s] readback failed: expected 0x%08x, found 0x%08x",
                     spec->name, expected, after);
            *failed = YES;
            break;
        }
        log_line("Patched [%s] @0x%llx: 0x%08x -> 0x%08x",
                 spec->name, (unsigned long long)patch_addr, before, after);

        g_patches[g_patched_count++] = (PatchRecord){patch_addr, expected};
        patched++;

        search_offset = match + 1;
    }
    return patched;
}

static float effect_dur_zero(id self, SEL _cmd) {
    return 0.0f;
}

// Keep Dock's temporary minimize/restore Space alive while it finishes ordering
// the window. Without this minimum lifetime, quitting an app with a minimized
// window and relaunching it can leave that window inaccessible: macOS treats it
// as being in another Space, but it cannot be brought back normally.
// Dock manages this lifetime; visual animation durations remain zero.
#define MIN_MAX_SPACE_MIN_LIFETIME 0.25

static void prepare_window_for_min_max(id self, SEL _cmd, uint32_t wid, double duration) {
    g_orig_prepare_min_max(self, _cmd, wid, fmax(duration, MIN_MAX_SPACE_MIN_LIFETIME));
}

static BOOL patch_prepare_min_max(void) {
    Method m = class_getInstanceMethod(objc_getClass("Spaces"),
                                      sel_registerName("prepareWindowForMinMax:duration:"));
    if (!m) {
        log_line("Missing -[Spaces prepareWindowForMinMax:duration:]");
        return NO;
    }
    if (method_getNumberOfArguments(m) != 4) {
        log_line("Unexpected argument count for -[Spaces prepareWindowForMinMax:duration:]");
        return NO;
    }
    char return_type[16] = {0};
    char window_type[16] = {0};
    char duration_type[16] = {0};
    method_getReturnType(m, return_type, sizeof(return_type));
    method_getArgumentType(m, 2, window_type, sizeof(window_type));
    method_getArgumentType(m, 3, duration_type, sizeof(duration_type));
    if (strcmp(return_type, @encode(void)) != 0 ||
        strcmp(window_type, @encode(uint32_t)) != 0 ||
        strcmp(duration_type, @encode(double)) != 0) {
        log_line("Unsupported prepareWindowForMinMax signature: return=%s, window=%s, duration=%s",
                 return_type, window_type, duration_type);
        return NO;
    }

    IMP original = method_getImplementation(m);
    if (!original || original == (IMP)prepare_window_for_min_max) {
        log_line("Cannot capture the original prepareWindowForMinMax implementation");
        return NO;
    }
    // Publish the original before installing the wrapper, which may run immediately.
    g_orig_prepare_min_max = (PrepareMinMaxIMP)original;
    method_setImplementation(m, (IMP)prepare_window_for_min_max);
    if (method_getImplementation(m) != (IMP)prepare_window_for_min_max) {
        log_line("Failed to verify -[Spaces prepareWindowForMinMax:duration:] override");
        return NO;
    }
    g_prepare_min_max_method = m;
    log_line("[min-max-space] swizzled -[Spaces prepareWindowForMinMax:duration:]: minimum %.2f seconds",
             MIN_MAX_SPACE_MIN_LIFETIME);
    return YES;
}

// -[DockBar effectDur] feeds the non-to-app min/max paths; swizzling avoids build-specific bytes
static BOOL patch_effect_dur(void) {
    Method m = class_getInstanceMethod(objc_getClass("DockBar"), sel_registerName("effectDur"));
    if (!m) {
        log_line("Missing -[DockBar effectDur]");
        return NO;
    }
    method_setImplementation(m, (IMP)effect_dur_zero);
    if (method_getImplementation(m) != (IMP)effect_dur_zero) {
        log_line("Failed to verify -[DockBar effectDur] override");
        return NO;
    }
    g_effect_dur_method = m;
    return YES;
}

// Apply minimize/unminimize patterns and the shared duration override.
// Validate every pattern before changing anything. Unsupported Dock builds must not
// leave a mixture of patched and unpatched effect paths merely because a match is absent.
static BOOL preflight_patterns(uint64_t text_start, uint64_t text_size) {
    int total = 0;
    for (int i = 0; i < g_pattern_count; i++) {
        PatternSpec *spec = &g_patterns[i];
        uint8_t bytes[128], mask[128];
        size_t length = parse_pattern(spec->pattern, bytes, mask, sizeof(bytes));
        if (!length) return NO;
        int count = 0;
        size_t offset = 0, match;
        while ((match = find_pattern((const uint8_t *)(uintptr_t)text_start, (size_t)text_size,
                                      bytes, mask, length, offset)) != SIZE_MAX) {
            uint64_t address = text_start + match + spec->patch_offset;
            if (spec->patch_offset < 0 || (address & 3) || text_size < sizeof(uint32_t) ||
                match + (size_t)spec->patch_offset > text_size - sizeof(uint32_t)) return NO;
            count++;
            offset = match + 1;
        }
        if (count < spec->min_matches) {
            log_line("Unsupported Dock: [%s] has %d sites; needs %d", spec->name, count, spec->min_matches);
            return NO;
        }
        total += count;
    }
    Method effect = class_getInstanceMethod(objc_getClass("DockBar"), sel_registerName("effectDur"));
    char return_type[16] = {0};
    if (!effect || method_getNumberOfArguments(effect) != 2) return NO;
    method_getReturnType(effect, return_type, sizeof(return_type));
    return strcmp(return_type, @encode(float)) == 0 && total <= (int)(sizeof(g_patches) / sizeof(g_patches[0]));
}

static InstantminiStatus patch_dock_text(uint64_t text_start, uint64_t text_size) {
    BOOL failed = NO;
    int complete_patterns = 0;

    NSOperatingSystemVersion os = [[NSProcessInfo processInfo] operatingSystemVersion];
    log_line("macOS version: %ld", (long)os.majorVersion);
    if (os.majorVersion != 27 || !preflight_patterns(text_start, text_size)) {
        log_line("Dock preflight failed; no patches applied");
        return INSTANTMINI_UNSUPPORTED;
    }

    // Install the preparation guard before any animation durations become zero.
    BOOL min_max_space_ok = patch_prepare_min_max();
    if (!min_max_space_ok) {
        log_line("Required min/max Space lifetime override unavailable; duration patches not applied");
        return INSTANTMINI_INCOMPLETE;
    }

    for (int i = 0; i < g_pattern_count; i++) {
        PatternSpec *spec = &g_patterns[i];

        int count = apply_pattern(spec, text_start, text_size, &failed);
        log_line("[%s] %d verified site(s), at least %d required",
                 spec->name, count, spec->min_matches);
        if (count >= spec->min_matches) {
            complete_patterns++;
        } else {
            log_line("[%s] incomplete", spec->name);
        }
        if (failed) break;
    }

    BOOL effect_dur_ok = !failed && patch_effect_dur();
    if (effect_dur_ok) {
        log_line("[effectDur-zero] swizzled -[DockBar effectDur]");
    }

    log_line("Verified: patterns=%d/%d, instructions=%d, effectDur=%s, minMaxSpace=%s",
             complete_patterns, g_pattern_count, g_patched_count,
             effect_dur_ok ? "yes" : "no", min_max_space_ok ? "yes" : "no");
    if (failed) return INSTANTMINI_PATCH_FAILED;
    if (complete_patterns != g_pattern_count || !effect_dur_ok) return INSTANTMINI_INCOMPLETE;
    return INSTANTMINI_SUCCESS;
}

// Caller holds g_patch_lock. Recheck retained sites without reapplying patches.
static InstantminiStatus verify_patches(void) {
    if (!g_patch_attempted) return INSTANTMINI_NOT_READY;
    if (g_patch_status != INSTANTMINI_SUCCESS) return g_patch_status;

    for (int i = 0; i < g_patched_count; i++) {
        PatchRecord patch = g_patches[i];
        uint32_t actual = *(volatile uint32_t *)patch.addr;
        if (actual != patch.expected) {
            log_line("Verification failed @0x%llx: expected 0x%08x, found 0x%08x",
                     (unsigned long long)patch.addr, patch.expected, actual);
            return INSTANTMINI_VERIFY_FAILED;
        }
    }
    if (!g_effect_dur_method ||
        method_getImplementation(g_effect_dur_method) != (IMP)effect_dur_zero) {
        log_line("Verification failed: -[DockBar effectDur] override changed");
        return INSTANTMINI_VERIFY_FAILED;
    }
    if (!g_prepare_min_max_method || !g_orig_prepare_min_max ||
        method_getImplementation(g_prepare_min_max_method) != (IMP)prepare_window_for_min_max) {
        log_line("Verification failed: -[Spaces prepareWindowForMinMax:duration:] override changed");
        return INSTANTMINI_VERIFY_FAILED;
    }
    return INSTANTMINI_SUCCESS;
}

// ============================================================================
#pragma mark - Public API
// ============================================================================

__attribute__((visibility("default")))
int instantmini_patch(void) {
#if !defined(__arm64__)
    return INSTANTMINI_UNSUPPORTED;
#else
    @autoreleasepool {
        pthread_mutex_lock(&g_patch_lock);
        if (g_patch_attempted) {
            InstantminiStatus status = verify_patches();
            pthread_mutex_unlock(&g_patch_lock);
            return status;
        }
        g_patch_attempted = YES;
        log_line("instantmini_patch started (minimize/unminimize)");

        uint64_t text_start = 0, text_size = 0;
        if (!find_dock_text(&text_start, &text_size)) {
            log_line("Failed to locate Dock __TEXT segment");
            g_patch_status = INSTANTMINI_PATCH_FAILED;
        } else {
            log_line("Dock __TEXT: 0x%llx - 0x%llx (%llu bytes)",
                     (unsigned long long)text_start,
                     (unsigned long long)(text_start + text_size),
                     (unsigned long long)text_size);
            g_patch_status = patch_dock_text(text_start, text_size);
        }
        InstantminiStatus status = verify_patches();
        log_line("Patch result: %s (status=%d)", instantmini_status_message(status), status);
        pthread_mutex_unlock(&g_patch_lock);
        return status;
    }
#endif
}

__attribute__((visibility("default")))
int instantmini_verify_v1(void) {
#if !defined(__arm64__)
    return INSTANTMINI_UNSUPPORTED;
#else
    @autoreleasepool {
        pthread_mutex_lock(&g_patch_lock);
        InstantminiStatus status = verify_patches();
        log_line("Verification result: %s (status=%d)", instantmini_status_message(status), status);
        pthread_mutex_unlock(&g_patch_lock);
        return status;
    }
#endif
}

#ifndef INSTANTMINIMIZE_TEST
__attribute__((constructor))
static void payload_init(void) {
    log_line("Payload loaded into Dock (pid=%d)", getpid());
    instantmini_patch();
}
#endif
