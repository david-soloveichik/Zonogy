# Instant Minimize patch and helper

Instant Minimize disables window minimize and restore animations across all applications by injecting a patch into Dock. The implementation is based on [instantmini](https://github.com/Razboy20/instantmini), with its Mach injection technique adapted from [yabai](https://github.com/koekeishiya/yabai). Apple Silicon required.

SIP must be partially disabled ([yabai’s SIP instructions](https://github.com/asmvik/yabai/wiki/Disabling-System-Integrity-Protection)):

1. Turn computer off
2. Press and hold the power button until "Loading startup options" appears.
Click Options, then click Continue.
3. In the menu bar, choose Utilities, then Terminal
4. Disable Filesystem Protections, Debugging Restrictions and NVRAM Protection:
`csrutil enable --without fs --without debug --without nvram`
5. Reboot
6. Enable non-Apple-signed arm64e binaries:
`sudo nvram boot-args=-arm64e_preview_abi`
7. Reboot again

`Zonogy-helper` patches the current user's Dock (needs administrator approval). It verifies its target before patching, then returns a JSON report describing whether patching succeeded and any errors.

The helper uses the bundled Mach loader when the `-arm64e_preview_abi` boot argument is enabled. Otherwise, it uses LLDB, which requires Apple's Command Line Tools.

For Zonogy's preferences, restart behavior, and crash recovery, see [SPECIFICATION.md](../../specs/SPECIFICATION.md).

Diagnostics appear in the macOS unified log under `com.dsemeas.zonogy`. Payload messages use the `InstantMinimizePayload` category.

## How the patch works

The injected `payload.dylib` changes animation durations in Dock's memory.

Dock uses different animation paths depending on “Minimize windows into application icon”:

- **Enabled:** The payload finds the ARM64 instructions that select the Genie, Scale, and Suck effect durations and replaces them with instructions that set the duration to zero. It patches both minimize and restore.
- **Disabled:** The payload overrides `-[DockBar effectDur]` to return zero, covering windows that minimize into separate Dock thumbnails.

The payload also wraps `-[Spaces prepareWindowForMinMax:duration:]`, keeping Dock’s temporary minimize/restore Space alive for at least 0.25 seconds. Without this minimum, quitting an application with a minimized window and relaunching it can leave that window inaccessible: macOS treats it as being in another (hidden) Space.

## Development checks

Run `bash scripts/build-instant-minimize.sh` to build and sign the native tools in `.build/InstantMinimize`. The app packaging script includes them in `Contents/Helpers/InstantMinimize`. These tools are built separately from `swift build`.

The native tests below cover payload validation and helper command handling. They run separately from Zonogy's `--self-test` and do not inject into Dock:

```sh
mkdir -p .build/InstantMinimize
xcrun clang -Wall -O2 -framework Cocoa Native/InstantMinimize/Tests.m -o .build/InstantMinimize/native-tests
.build/InstantMinimize/native-tests
xcrun clang -Wall -O2 -framework Foundation Native/InstantMinimize/HelperTests.m -o .build/InstantMinimize/helper-tests
.build/InstantMinimize/helper-tests
```
