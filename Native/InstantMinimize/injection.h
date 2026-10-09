#ifndef INSTANTMINI_INJECTION_H
#define INSTANTMINI_INJECTION_H

// Shared layout for the loader and copied ARM64e code. No target file is used.
#define REMOTE_CREATE_OFFSET         0
#define REMOTE_DLOPEN_OFFSET         8
#define REMOTE_DLSYM_OFFSET         16
#define REMOTE_DLERROR_OFFSET       24
#define REMOTE_BOOTSTRAP_OFFSET     32
#define REMOTE_RESULT_OFFSET        36
#define REMOTE_THREAD_ERROR_OFFSET  40
#define REMOTE_PATCH_STATUS_OFFSET  44
#define REMOTE_PATH_OFFSET          48
#define REMOTE_PATH_CAPACITY      1024
#define REMOTE_VERIFIER_OFFSET    1072
#define REMOTE_VERIFIER_CAPACITY    32
#define REMOTE_ERROR_OFFSET       1104
#define REMOTE_ERROR_CAPACITY      256
#define REMOTE_CONTEXT_SIZE       1360

#define REMOTE_PENDING          0
#define REMOTE_VERIFIED         1
#define REMOTE_PTHREAD_FAILED   2
#define REMOTE_DLOPEN_FAILED    3
#define REMOTE_DLSYM_FAILED     4
#define REMOTE_PATCH_FAILED     5

#ifndef __ASSEMBLER__
#include <stddef.h>
#include <stdint.h>

typedef struct {
    uint64_t pthread_create_addr;
    uint64_t dlopen_addr;
    uint64_t dlsym_addr;
    uint64_t dlerror_addr;
    uint32_t bootstrap_done;
    uint32_t result;
    int32_t thread_error;
    int32_t patch_status;
    char payload_path[REMOTE_PATH_CAPACITY];
    char verifier[REMOTE_VERIFIER_CAPACITY];
    char error[REMOTE_ERROR_CAPACITY];
} InjectionContext;

#define CHECK_OFFSET(field, offset) \
    _Static_assert(offsetof(InjectionContext, field) == offset, "Remote field offset mismatch: " #field)
CHECK_OFFSET(pthread_create_addr, REMOTE_CREATE_OFFSET);
CHECK_OFFSET(dlopen_addr, REMOTE_DLOPEN_OFFSET);
CHECK_OFFSET(dlsym_addr, REMOTE_DLSYM_OFFSET);
CHECK_OFFSET(dlerror_addr, REMOTE_DLERROR_OFFSET);
CHECK_OFFSET(bootstrap_done, REMOTE_BOOTSTRAP_OFFSET);
CHECK_OFFSET(result, REMOTE_RESULT_OFFSET);
CHECK_OFFSET(thread_error, REMOTE_THREAD_ERROR_OFFSET);
CHECK_OFFSET(patch_status, REMOTE_PATCH_STATUS_OFFSET);
CHECK_OFFSET(payload_path, REMOTE_PATH_OFFSET);
CHECK_OFFSET(verifier, REMOTE_VERIFIER_OFFSET);
CHECK_OFFSET(error, REMOTE_ERROR_OFFSET);
#undef CHECK_OFFSET
_Static_assert(sizeof(InjectionContext) == REMOTE_CONTEXT_SIZE, "Remote context size mismatch");
#endif

#endif
