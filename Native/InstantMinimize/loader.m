// instantmini loader - injects payload into Dock via Mach APIs
//
// Based on injection technique from yabai by koekeishiya (Jeremy Legendre).
// Expected runtime: macOS 27 on Apple Silicon (arm64e).
// Requires permission to inject into Dock.

#import <Cocoa/Cocoa.h>
#import <mach/mach.h>
#import <mach/mach_vm.h>
#import <dlfcn.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>
#import <ptrauth.h>
#include "injection.h"
#include "status.h"
#include "target.h"

// Private API for thread state conversion (arm64e PAC)
static kern_return_t (*_thread_convert_thread_state)(
    thread_act_t thread, int direction, thread_state_flavor_t flavor,
    thread_state_t in_state, mach_msg_type_number_t in_stateCnt,
    thread_state_t out_state, mach_msg_type_number_t *out_stateCnt
);

// Assembly has no external relocations; all target addresses live in the context.
extern const unsigned char instantmini_remote_start[];
extern const unsigned char instantmini_remote_end[];

_Static_assert(sizeof(INSTANTMINI_VERIFY_SYMBOL) <= REMOTE_VERIFIER_CAPACITY,
               "Verifier name exceeds remote context capacity");

static BOOL load_thread_convert(void) {
    void *handle = dlopen("/usr/lib/system/libsystem_kernel.dylib", RTLD_GLOBAL | RTLD_LAZY);
    if (!handle) return NO;
    _thread_convert_thread_state = dlsym(handle, "thread_convert_thread_state");
    dlclose(handle);
    return _thread_convert_thread_state != NULL;
}

static uint64_t shared_function(const char *name) {
    void *address = dlsym(RTLD_DEFAULT, name);
    if (!address) {
        fprintf(stderr, "error: required injection function is unavailable: %s\n", name);
        return 0;
    }
    return (uint64_t)ptrauth_strip(address, ptrauth_key_function_pointer);
}

static BOOL read_remote(task_t task, mach_vm_address_t address, void *buffer,
                        mach_vm_size_t size) {
    mach_vm_size_t copied = 0;
    kern_return_t kr = mach_vm_read_overwrite(task, address, size,
                                             (mach_vm_address_t)buffer, &copied);
    if (kr != KERN_SUCCESS || copied != size) {
        fprintf(stderr, "error: cannot read injection result: %s (%llu/%llu bytes)\n",
                mach_error_string(kr), (unsigned long long)copied, (unsigned long long)size);
        return NO;
    }
    return YES;
}

static int report_result(const InjectionContext *context) {
    switch (context->result) {
        case REMOTE_VERIFIED:
            // Fail closed if the terminal flag and payload status disagree.
            if (context->patch_status != INSTANTMINI_SUCCESS) break;
            fprintf(stderr, "Payload loaded and all required patches verified\n");
            return 0;
        case REMOTE_PTHREAD_FAILED:
            fprintf(stderr, "error: pthread creation failed: %s (%d)\n",
                    strerror(context->thread_error), context->thread_error);
            return 1;
        case REMOTE_DLOPEN_FAILED:
            fprintf(stderr, "error: dlopen failed: %s\n",
                    context->error[0] ? context->error : "no detail available");
            return 1;
        case REMOTE_DLSYM_FAILED:
            fprintf(stderr, "error: payload verification function is unavailable: %s\n",
                    context->error[0] ? context->error : "no detail available");
            fprintf(stderr, "hint: rebuild/install and restart Dock to replace an older loaded payload\n");
            return 1;
        case REMOTE_PATCH_FAILED:
            fprintf(stderr, "error: payload verification failed: %s (status=%d)\n",
                    instantmini_status_message(context->patch_status), context->patch_status);
            fprintf(stderr, "hint: inspect the payload log with make logs\n");
            return 1;
        default:
            break;
    }
    fprintf(stderr, "error: invalid injection result (result=%u, payload status=%d)\n",
            context->result, context->patch_status);
    return 1;
}

static int inject_payload(task_t task, const char *payload_path) {
    const mach_vm_size_t stack_size = 16 * 1024;
    const mach_vm_size_t code_size = (uintptr_t)instantmini_remote_end -
                                     (uintptr_t)instantmini_remote_start;
    mach_vm_address_t stack = 0, code = 0, data = 0;
    thread_act_t thread = MACH_PORT_NULL;
    BOOL started = NO;
    int result = 1;
    kern_return_t kr;
    arm_thread_state64_t state = {}, machine_state = {};
    mach_msg_type_number_t machine_count = ARM_THREAD_STATE64_COUNT;
    InjectionContext context = {
        .pthread_create_addr = shared_function("pthread_create_from_mach_thread"),
        .dlopen_addr = shared_function("dlopen"),
        .dlsym_addr = shared_function("dlsym"),
        .dlerror_addr = shared_function("dlerror"),
        .patch_status = INSTANTMINI_NOT_READY,
    };
    if (!context.pthread_create_addr || !context.dlopen_addr ||
        !context.dlsym_addr || !context.dlerror_addr) return 1;
    memcpy(context.payload_path, payload_path, strlen(payload_path) + 1);
    memcpy(context.verifier, INSTANTMINI_VERIFY_SYMBOL, sizeof(INSTANTMINI_VERIFY_SYMBOL));

    kr = mach_vm_allocate(task, &stack, stack_size, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "error: failed to allocate stack: %s\n", mach_error_string(kr));
        goto cleanup;
    }
    kr = mach_vm_protect(task, stack, stack_size, TRUE, VM_PROT_READ | VM_PROT_WRITE);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "error: failed to protect stack: %s\n", mach_error_string(kr));
        goto cleanup;
    }
    kr = mach_vm_allocate(task, &data, sizeof(context), VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "error: failed to allocate result context: %s\n", mach_error_string(kr));
        goto cleanup;
    }
    kr = mach_vm_write(task, data, (vm_offset_t)&context, sizeof(context));
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "error: failed to write result context: %s\n", mach_error_string(kr));
        goto cleanup;
    }
    kr = mach_vm_allocate(task, &code, code_size, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "error: failed to allocate code: %s\n", mach_error_string(kr));
        goto cleanup;
    }
    kr = mach_vm_write(task, code, (vm_offset_t)instantmini_remote_start,
                       (mach_msg_type_number_t)code_size);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "error: failed to write code: %s\n", mach_error_string(kr));
        goto cleanup;
    }
    kr = mach_vm_protect(task, code, code_size, FALSE, VM_PROT_EXECUTE | VM_PROT_READ);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "error: failed to protect code: %s\n", mach_error_string(kr));
        goto cleanup;
    }

    __darwin_arm_thread_state64_set_pc_fptr(
        state, ptrauth_sign_unauthenticated((void *)code, ptrauth_key_asia, 0));
    __darwin_arm_thread_state64_set_sp(state, stack + (stack_size / 2));
    state.__x[0] = data;

    kr = thread_create(task, &thread);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "error: failed to create thread: %s\n", mach_error_string(kr));
        goto cleanup;
    }
    kr = _thread_convert_thread_state(
        thread, 2, ARM_THREAD_STATE64, (thread_state_t)&state, ARM_THREAD_STATE64_COUNT,
        (thread_state_t)&machine_state, &machine_count);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "error: failed to convert thread state: %s\n", mach_error_string(kr));
        goto cleanup;
    }

    // The setup thread is only needed for arm64e state conversion.
    kr = thread_terminate(thread);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "error: failed to remove setup thread: %s\n", mach_error_string(kr));
        goto cleanup;
    }
    mach_port_deallocate(mach_task_self(), thread);
    thread = MACH_PORT_NULL;
    fprintf(stderr, "ZONOGY_INJECTION_STARTED\n");
    kr = thread_create_running(task, ARM_THREAD_STATE64, (thread_state_t)&machine_state,
                               machine_count, &thread);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "error: failed to start injection thread: %s\n", mach_error_string(kr));
        goto cleanup;
    }
    started = YES;

    // Thread creation is not success. Wait up to 10 seconds for payload verification.
    for (int attempt = 0; attempt < 500; attempt++) {
        uint32_t flags[2]; // bootstrap_done, result
        if (!read_remote(task, data + REMOTE_BOOTSTRAP_OFFSET, flags, sizeof(flags))) goto cleanup;
        if (flags[0] && thread != MACH_PORT_NULL) {
            kr = thread_terminate(thread);
            if (kr != KERN_SUCCESS) {
                fprintf(stderr, "error: failed to stop bootstrap thread: %s\n", mach_error_string(kr));
                goto cleanup;
            }
            mach_port_deallocate(mach_task_self(), thread);
            thread = MACH_PORT_NULL;
        }
        if (flags[0] && flags[1] != REMOTE_PENDING) {
            // Read diagnostics only after observing the worker's published result.
            if (!read_remote(task, data, &context, sizeof(context))) goto cleanup;
            context.error[sizeof(context.error) - 1] = '\0';
            result = report_result(&context);
            goto cleanup;
        }
        usleep(20000);
    }
    fprintf(stderr, "error: timed out waiting for payload verification; remote work may still finish\n");

cleanup:
    if (thread != MACH_PORT_NULL) {
        // A running bootstrap may still be inside pthread_create. Do not kill it there.
        if (!started) thread_terminate(thread);
        mach_port_deallocate(mach_task_self(), thread);
    }
    if (stack && (!started || thread == MACH_PORT_NULL)) mach_vm_deallocate(task, stack, stack_size);
    // After dispatch the worker may still be returning through copied code, even
    // after publishing its result. Keep code/context mapped until Dock exits.
    if (!started) {
        if (code) mach_vm_deallocate(task, code, code_size);
        if (data) mach_vm_deallocate(task, data, sizeof(context));
    }
    return result;
}

// The caller fixes the Dock identity before any administrator prompt. Never rediscover a PID.
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 5) {
            fprintf(stderr, "Usage: loader dock-pid user-id start-time payload-path\n");
            return 64;
        }
        if (!validate_dock(argv[1], argv[2], argv[3])) {
            fprintf(stderr, "error: Dock identity changed\n");
            return 78;
        }
        const char *payload_path = argv[4];
        if (strlen(payload_path) >= REMOTE_PATH_CAPACITY || access(payload_path, R_OK)) {
            fprintf(stderr, "error: payload path is too long or unreadable\n");
            return 78;
        }
        if (!load_thread_convert()) {
            fprintf(stderr, "error: thread state conversion is unavailable\n");
            return 78;
        }
        mach_port_t task = MACH_PORT_NULL;
        kern_return_t kr = task_for_pid(mach_task_self(), (pid_t)strtol(argv[1], NULL, 10), &task);
        if (kr != KERN_SUCCESS) {
            fprintf(stderr, "error: task_for_pid failed: %s\n", mach_error_string(kr));
            return 77;
        }
        int result = inject_payload(task, payload_path);
        mach_port_deallocate(mach_task_self(), task);
        return result;
    }
}
