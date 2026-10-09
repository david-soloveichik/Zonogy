#include "injection.h"

// Position-independent code copied into Dock. x0 points to a separate RW context.
// External calls use stripped shared-cache addresses supplied by the loader.
.text
.p2align 2
.globl _instantmini_remote_start
.globl _instantmini_remote_end

_instantmini_remote_start:
    sub sp, sp, #32
    mov x19, x0
    add x0, sp, #8
    mov x1, #0
    adr x2, Lpayload_thread
    paciza x2
    mov x3, x19
    ldr x9, [x19, #REMOTE_CREATE_OFFSET]
    blr x9
    cbz w0, Lbootstrap_done
    str w0, [x19, #REMOTE_THREAD_ERROR_OFFSET]
    mov w9, #REMOTE_PTHREAD_FAILED
    add x10, x19, #REMOTE_RESULT_OFFSET
    stlr w9, [x10]

Lbootstrap_done:
    // The host may terminate this Mach thread only after pthread_create returns.
    mov w9, #1
    add x10, x19, #REMOTE_BOOTSTRAP_OFFSET
    stlr w9, [x10]
Lbootstrap_wait:
    wfe
    b Lbootstrap_wait

Lpayload_thread:
    pacibsp
    stp x29, x30, [sp, #-32]!
    stp x19, x20, [sp, #16]
    mov x29, sp
    mov x19, x0

    add x0, x19, #REMOTE_PATH_OFFSET
    mov x1, #2 // RTLD_NOW; constructors finish before dlopen returns.
    ldr x9, [x19, #REMOTE_DLOPEN_OFFSET]
    blr x9
    cbz x0, Lload_failed

    add x1, x19, #REMOTE_VERIFIER_OFFSET
    ldr x9, [x19, #REMOTE_DLSYM_OFFSET]
    blr x9
    cbz x0, Lsymbol_failed

    // dlsym returns an authenticated function pointer on arm64e.
    blraaz x0
    str w0, [x19, #REMOTE_PATCH_STATUS_OFFSET]
    mov w20, #REMOTE_VERIFIED
    cbz w0, Lpublish_result
    mov w20, #REMOTE_PATCH_FAILED
    b Lpublish_result

Lload_failed:
    mov w20, #REMOTE_DLOPEN_FAILED
    b Lcopy_error
Lsymbol_failed:
    mov w20, #REMOTE_DLSYM_FAILED
Lcopy_error:
    ldr x9, [x19, #REMOTE_DLERROR_OFFSET]
    blr x9
    cbz x0, Lpublish_result
    add x1, x19, #REMOTE_ERROR_OFFSET
    mov w11, #(REMOTE_ERROR_CAPACITY - 1)
Lcopy_error_byte:
    ldrb w10, [x0], #1
    strb w10, [x1], #1
    cbz w10, Lpublish_result
    subs w11, w11, #1
    b.ne Lcopy_error_byte
    strb wzr, [x1]

Lpublish_result:
    // Publish diagnostics and verification status before the terminal result.
    add x10, x19, #REMOTE_RESULT_OFFSET
    stlr w20, [x10]
    mov x0, #0
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    retab

_instantmini_remote_end:
