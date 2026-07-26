# Cutting a Zonogy Release

This is the release runbook: how to go from the current `main` to a published GitHub release that running copies of Zonogy discover through the software update check (see the Software Updates section of [SPECIFICATION.md](SPECIFICATION.md)).

## One-Time Prerequisites

- A "Developer ID Application" certificate installed in the login keychain.
- Notarization credentials stored under a keychain profile (default name `zonogy-notary`) via `xcrun notarytool store-credentials`.
- The GitHub CLI (`gh`) authenticated, for publishing the release.

`scripts/release.sh` honors these environment overrides: `ZONOGY_SIGN_IDENTITY` (codesign identity), `ZONOGY_NOTARY_PROFILE` (notarytool profile name), `ZONOGY_VERSION` (version used in artifact filenames; defaults to the Info.plist value), and `ZONOGY_ALLOW_DIRTY=1` (skip the clean-working-tree check).

## Steps

1. **Bump the version.** Set `CFBundleShortVersionString` in `Resources/Info.plist` (for example `1.1`). This one value drives the artifact filenames, the version the app reports, and what the update check compares against. (The build number in `CFBundleVersion` and the git hash are stamped automatically by `scripts/build.sh` at package time; the source plist's `CFBundleVersion` is just a numeric placeholder and needs no editing.)

   For a beta, give the version a pre-release suffix like `1.0-beta.1` (then `1.0-beta.2`, and so on). Zonogy shows the version verbatim, so the beta marker appears in the menu bar and Preferences, and the update check orders each beta before the eventual final `1.0`.

2. **Commit and push.** Commit before building so the stamped build number and git hash match the released code; `release.sh` refuses to run from a dirty working tree.

3. **Build, sign, notarize.** Run `./scripts/release.sh`. It builds the app bundle, signs it with the Developer ID and hardened runtime, notarizes and staples both the app and the DMG, and writes `dist/Zonogy-<version>.dmg`. (The zip submitted to the notary service is created in a temporary directory and cleaned up automatically.)

4. **Publish the GitHub release.** `release.sh` prints this command with the built commit filled in:

   ```sh
   gh release create v1.1 dist/Zonogy-1.1.dmg --target <built commit> --title "Zonogy 1.1" --notes "What changed…"
   ```

   `--target` pins the release tag to the exact commit the DMG was built from, and fails if that commit was never pushed. (Without it, GitHub creates a missing tag from the remote default branch, which can point at different code than the packaged commit.) The tag is the version with a leading `v` (the update check strips the `v` before comparing). For a beta the tag carries the suffix too (e.g. tag `v1.0-beta.1`, title "Zonogy 1.0 beta 1").

   **Betas.** During the initial beta phase, publish each beta as an ordinary release so testers' update checks offer the next one; version ordering makes each beta supersede the last, and the final `v1.0` supersede them all. Mark a release **draft or prerelease** only to hide it from the update check entirely — for example, once a stable release exists and you don't want its users pulled onto a new beta. (People who manually install a hidden beta then aren't auto-notified of further betas until a normal release appears.)

5. **Verify.** From an older installed build, choose "Check for Updates..." in the Zonogy menu bar menu and confirm the new version is offered. Running apps with automatic checking enabled see the alert within a day.

## Download Counts

Each release asset's download count is available from the GitHub API:

```sh
gh api repos/david-soloveichik/Zonogy/releases \
  --jq '.[] | .tag_name, (.assets[] | "  \(.name): \(.download_count)")'
```
