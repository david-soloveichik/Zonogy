#ifndef INSTANTMINI_STATUS_H
#define INSTANTMINI_STATUS_H

// A new symbol prevents an older payload's patch count from being read as status.
#define INSTANTMINI_VERIFY_SYMBOL "instantmini_verify_v1"

typedef enum {
    INSTANTMINI_SUCCESS = 0,
    INSTANTMINI_NOT_READY = 1,
    INSTANTMINI_INCOMPLETE = 2,
    INSTANTMINI_PATCH_FAILED = 3,
    INSTANTMINI_VERIFY_FAILED = 4,
    INSTANTMINI_UNSUPPORTED = 5,
} InstantminiStatus;

static inline const char *instantmini_status_message(int status) {
    switch (status) {
        case INSTANTMINI_SUCCESS: return "all required patches verified";
        case INSTANTMINI_NOT_READY: return "patching has not completed";
        case INSTANTMINI_INCOMPLETE: return "required patches are missing";
        case INSTANTMINI_PATCH_FAILED: return "patching failed";
        case INSTANTMINI_VERIFY_FAILED: return "a patched instruction or method changed";
        case INSTANTMINI_UNSUPPORTED: return "unsupported Dock build or architecture";
        default: return "unknown payload status";
    }
}

int instantmini_patch(void);
int instantmini_verify_v1(void);

#endif
