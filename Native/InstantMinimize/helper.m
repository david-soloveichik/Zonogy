// Zonogy-helper runs bundled Dock injection tools, optionally with an administrator prompt, and returns JSON.
#import <Foundation/Foundation.h>
#import <mach/mach.h>
#include <sys/sysctl.h>
#include <limits.h>
#include "target.h"

static NSDictionary *result(NSString *status, BOOL needs_restart, NSString *message) {
    return @{@"status": status, @"needsDockRestart": @(needs_restart), @"message": message};
}

static NSString *shell_quote(NSString *value) {
    return [NSString stringWithFormat:@"'%@'", [value stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}

static NSAppleEventDescriptor *command_event(NSString *command) {
    NSAppleEventDescriptor *event = [NSAppleEventDescriptor appleEventWithEventClass:kCoreEventClass
        eventID:kAEOpenApplication targetDescriptor:nil returnID:kAutoGenerateReturnID transactionID:kAnyTransactionID];
    NSAppleEventDescriptor *parameters = [NSAppleEventDescriptor listDescriptor];
    [parameters insertDescriptor:[NSAppleEventDescriptor descriptorWithString:command] atIndex:1];
    [event setParamDescriptor:parameters forKeyword:keyDirectObject];
    return event;
}

static NSDictionary *authorize(NSArray<NSString *> *arguments) {
    // AppleScript receives the command as data, never as interpolated AppleScript source.
    NSMutableArray *words = [NSMutableArray array];
    for (NSString *argument in arguments) [words addObject:shell_quote(argument)];
    NSString *command = [@"exec " stringByAppendingString:[words componentsJoinedByString:@" "]];
    NSAppleScript *script = [[NSAppleScript alloc] initWithSource:
        @"on run argv\nreturn do shell script (item 1 of argv) with administrator privileges\nend run"];
    NSDictionary *error = nil;
    NSAppleEventDescriptor *reply = [script executeAppleEvent:command_event(command) error:&error];
    if (!reply) {
        if ([error[NSAppleScriptErrorNumber] integerValue] == -128)
            return result(@"failed", NO, @"Administrator authorization was cancelled.");
        return result(@"failed", YES, error[NSAppleScriptErrorMessage] ?: @"Administrator authorization failed.");
    }
    NSData *data = [[reply stringValue] dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *decoded = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [decoded isKindOfClass:[NSDictionary class]] ? decoded :
        result(@"failed", YES, @"The administrator helper did not return a verification result.");
}

static BOOL native_loader_supported(void) {
    char args[4096] = {0};
    size_t size = sizeof(args) - 1;
    return sysctlbyname("kern.bootargs", args, &size, NULL, 0) == 0 && strstr(args, "-arm64e_preview_abi") != NULL;
}

static NSDictionary *inject(NSArray<NSString *> *arguments, NSString *directory) {
    NSString *payload = [directory stringByAppendingPathComponent:@"payload.dylib"];
    BOOL native = native_loader_supported();
    NSString *executable = native ? [directory stringByAppendingPathComponent:@"loader"] : @"/usr/bin/lldb";
    if (access([payload fileSystemRepresentation], R_OK) || access([executable fileSystemRepresentation], X_OK))
        return result(@"failed", NO, @"The bundled injection tools or Apple's command line tools are missing.");

    // A read-only permission check avoids invoking a debugger (and possibly stopping Dock)
    // before we know that attachment is allowed. Root does not bypass SIP restrictions.
    mach_port_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), [arguments[0] intValue], &task);
    if (kr != KERN_SUCCESS)
        return result(@"permissionDenied", NO,
            [NSString stringWithFormat:@"macOS denied access to Dock (%s). Compatible SIP and developer-tool settings are required.", mach_error_string(kr)]);
    mach_port_deallocate(mach_task_self(), task);

    NSTask *process = [[NSTask alloc] init];
    process.executableURL = [NSURL fileURLWithPath:executable];
    if (native) {
        process.arguments = [arguments arrayByAddingObject:payload];
    } else {
        // Paths are passed through environment variables, not embedded in LLDB commands.
        NSMutableDictionary *environment = [[[NSProcessInfo processInfo] environment] mutableCopy];
        environment[@"ZONOGY_PAYLOAD"] = payload;
        environment[@"ZONOGY_LLDB_SCRIPT"] = [directory stringByAppendingPathComponent:@"lldb_inject.py"];
        process.environment = environment;
        process.arguments = @[@"--no-lldbinit", @"--batch", @"-p", arguments[0],
            @"-O", @"script import sys; sys.dont_write_bytecode = True",
            @"-O", @"script import os; import importlib.util; s = importlib.util.spec_from_file_location('zonogy_inject', os.environ['ZONOGY_LLDB_SCRIPT']); m = importlib.util.module_from_spec(s); sys.modules[s.name] = m; s.loader.exec_module(m); m.__lldb_init_module(lldb.debugger, {})",
            @"-o", @"instantmini-inject"];
    }
    NSPipe *output = [NSPipe pipe];
    process.standardOutput = output;
    process.standardError = output;
    NSError *error = nil;
    if (![process launchAndReturnError:&error]) return result(@"failed", NO, error.localizedDescription);
    NSData *data = [output.fileHandleForReading readDataToEndOfFile];
    [process waitUntilExit];
    NSString *detail = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"Injection failed.";
    // Preserve full diagnostics in Zonogy's log; the Swift UI supplies the short status text.
    if (process.terminationReason == NSTaskTerminationReasonExit && process.terminationStatus == 0)
        return result(@"active", YES, detail);
    if (native && process.terminationStatus == 77) return result(@"permissionDenied", NO, detail);
    // A failed debugger can also leave Dock stopped before it evaluates our command.
    return result(@"failed", !native || [detail containsString:@"ZONOGY_INJECTION_STARTED"], detail);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 5 || (strcmp(argv[1], "--inject") && strcmp(argv[1], "--authorize") && strcmp(argv[1], "--check"))) {
            fprintf(stderr, "Usage: Zonogy-helper --inject|--authorize|--check dock-pid user-id start-time\n");
            return 64;
        }
        NSArray<NSString *> *arguments = @[@(argv[2]), @(argv[3]), @(argv[4])];
        NSDictionary *answer;
        if (!validate_dock(argv[2], argv[3], argv[4])) {
            answer = result(@"failed", NO, @"The selected Dock process has exited or changed. Toggle the setting to retry.");
        } else if (!strcmp(argv[1], "--authorize")) {
            NSString *self_path = [[[NSProcessInfo processInfo] arguments][0] stringByStandardizingPath];
            answer = authorize([@[self_path, @"--inject"] arrayByAddingObjectsFromArray:arguments]);
        } else if (!strcmp(argv[1], "--check")) {
            // A diagnostic probe only: no attachment, injection, authorization, or Dock restart.
            answer = result(@"checked", NO, @"Dock identity verified.");
        } else {
            NSString *directory = [[[[NSProcessInfo processInfo] arguments][0] stringByStandardizingPath] stringByDeletingLastPathComponent];
            answer = inject(arguments, directory);
        }
        NSData *json = [NSJSONSerialization dataWithJSONObject:answer options:0 error:nil];
        fwrite(json.bytes, 1, json.length, stdout);
        fputc('\n', stdout);
        return 0;
    }
}
