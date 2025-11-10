# Rules for AI Agents working on LatticeTopology

- Claude should not read or modify files in ./PLANNING/ unless explicitly told to.
- Unless otherwise told, Agent should read the SPECIFICATION.md file since it gives the big-picture perspective on the project.
- The desired specification is in SPECIFICATION.md. If told to _implement the updated specification_, Agent should use `git diff SPECIFICATION.md` to see uncommitted changes and implement only those changes. (Ignoring minor formatting changes in SPECIFICATION.md file.) Afterward, if Agent noticed errors in the updates to the specification, it should tell the user what they are and offer to fix them.
- When git committing, Agent should include SPECIFICATION.md if it was changed by Agent or the user.
- When Agent is asked to commit, please split `git add` and `git commit -m ...` in _separate shell calls_, allowing the user to not approve the second while still approving the first
- After making changes, the Agent should rebuild the tool to make sure that there are no errors, and to make sure that the user can easily execute the new version.
- Agent should prefer each code file to have a single responsibility ensuring that code files don't get too large. Each code file should have a concise description header of its responsibility that is maintained up to date
- Agent should not worry about preserving backward compatibility

## Rules for Codex ONLY (Claude ignores this whole section)

Elevated privileges (IMPORTANT!):

- If running `swift build` or other commands gives a sandbox error, ask me for approval to run with elevated privileges.
- If you encounter path errors, the path should be correct in zsh (rather than bash).
- Tools requiring accessibility APIs should also be run with elevated privileges in zsh. Without it, tools like `winmanmon` will misleadingly err saying "Please grant accessibility access in System Preferences". Note: `winmanmon` is in the zsh path.

Other:

- Codex's commit messages should be relatively detailed, at least a few lines long
