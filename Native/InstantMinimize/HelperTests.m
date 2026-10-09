// Tests command quoting and AppleScript argument transport; no authorization or shell execution.
#define main instant_minimize_helper_main
#include "helper.m"
#undef main
#include <assert.h>

int main(void) {
    @autoreleasepool {
        assert([shell_quote(@"a'b $(unused)") isEqualToString:@"'a'\\''b $(unused)'"]);
        assert(!validate_dock("0", "501", "1"));
        assert(!validate_dock("1x", "501", "1"));
        assert(!validate_dock("100", "501", "nan"));
        NSString *value = @"spaces ' quotes \" backticks ` and $()\nremain data";
        NSAppleScript *script = [[NSAppleScript alloc] initWithSource:@"on run argv\nreturn item 1 of argv\nend run"];
        NSDictionary *error = nil;
        NSAppleEventDescriptor *reply = [script executeAppleEvent:command_event(value) error:&error];
        if (![reply.stringValue isEqualToString:value]) {
            fprintf(stderr, "AppleScript argument test failed: %s\n", [[error description] UTF8String]);
            return 1;
        }
        puts("InstantMinimize helper tests: all tests passed");
        return 0;
    }
}
