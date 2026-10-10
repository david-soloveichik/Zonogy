"""LLDB command that loads instantmini and requires successful verification."""

import json
import os

import lldb


# Keep these status values in sync with src/status.h.
VERIFY_SYMBOL = "instantmini_verify_v1"
STATUS_MESSAGES = {
    1: "patching has not completed",
    2: "required patches are missing",
    3: "patching failed",
    4: "a patched instruction or method changed",
    5: "unsupported Dock build or architecture",
}


def inject(debugger, command, exe_ctx, result, internal_dict):
    process = exe_ctx.GetProcess()
    errors = []
    try:
        if command.strip():
            raise ValueError("usage: instantmini-inject")
        payload_path = os.environ["ZONOGY_PAYLOAD"]
        if not process.IsValid():
            raise RuntimeError("no attached process")

        options = lldb.SBExpressionOptions()
        options.SetLanguage(lldb.eLanguageTypeObjC_plus_plus)
        options.SetTimeoutInMicroSeconds(10_000_000)
        options.SetOneThreadTimeoutInMicroSeconds(1_000_000)
        options.SetTryAllThreads(True)
        options.SetIgnoreBreakpoints(True)
        options.SetUnwindOnError(True)
        target = exe_ctx.GetTarget()
        path_literal = json.dumps(payload_path)
        expression = """({
            void *handle = (void *)dlopen(%s, 2);
            int status = -1;
            if (handle) {
                int (*verify)(void) = (int (*)(void))(void *)dlsym(handle, "%s");
                status = verify ? verify() : -2;
            }
            status;
        })""" % (path_literal, VERIFY_SYMBOL)
        print("ZONOGY_INJECTION_STARTED: LLDB pipeline", flush=True)
        value = target.EvaluateExpression(expression, options)
        if not value.IsValid() or value.GetError().Fail():
            raise RuntimeError("could not evaluate injection: %s" % value.GetError())
        conversion_error = lldb.SBError()
        status = value.GetValueAsSigned(conversion_error, -3)
        if conversion_error.Fail():
            raise RuntimeError("could not read verification status: %s" % conversion_error)
        if status in (-1, -2):
            detail = target.EvaluateExpression("(char *)dlerror()", options)
            description = None
            if detail.IsValid() and detail.GetError().Success():
                description = detail.GetSummary()
            if status == -1:
                message = "dlopen failed"
            else:
                message = ("payload verification function is unavailable; rebuild/install "
                           "and restart Dock to replace an older loaded payload")
            raise RuntimeError(message + (": " + description if description else ""))
        if status != 0:
            raise RuntimeError("payload verification failed: %s (status=%d); see make logs" %
                               (STATUS_MESSAGES.get(status, "unknown payload status"), status))
    except Exception as error:
        errors.append(str(error))
    finally:
        # Release Dock on verification failures as well as success.
        if process.IsValid():
            try:
                detach_error = process.Detach()
                if detach_error.Fail():
                    errors.append("could not detach from Dock: %s" % detach_error)
            except Exception as error:
                errors.append("could not detach from Dock: %s" % error)

    if errors:
        # A failed command makes LLDB batch mode exit nonzero.
        result.SetError("; ".join(errors))
    else:
        result.AppendMessage("Payload loaded and all required patches verified")
        result.SetStatus(lldb.eReturnStatusSuccessFinishResult)


def __lldb_init_module(debugger, internal_dict):
    debugger.HandleCommand("command script add -f %s.inject instantmini-inject" % __name__)
