# Rules for AI Agents working on Zonogy

- Agent should not read or modify files in ./PLANNING/ unless explicitly told to.
- Unless otherwise told, Agent should read README.md and SPECIFICATION.md files since they give the big-picture perspective on the project.
- The desired specification is in SPECIFICATION.md. If told to _implement the updated specification_, Agent should use `git diff SPECIFICATION.md` to see uncommitted changes and implement only those changes. (Ignoring minor formatting changes in SPECIFICATION.md file.) Afterward, if Agent noticed errors in the updates to the specification, it should tell the user what they are and offer to fix them.
- When git committing, Agent should include SPECIFICATION.md if it was changed by Agent or the user.
- When Agent is asked to commit, please split `git add` and `git commit -m ...` in _separate shell calls_, allowing the user to stage / unstage, or change something something in between the two calls. IMPORTANT: The commit message should identify the Agent (eg claude or codex) at the end.
- After making changes to code files, the Agent should rebuild the tool to make sure that there are no errors, and to make sure that the user can easily execute the new version.
- When adding/refactoring pure deterministic logic (geometry/policy/selection), Agent should add or update a `--self-test` guardrail test when the logic is non-trivial and its correctness may not be obvious from inspection (for example: meaningful branching, ordering/tie-breaking, state transitions, or important invariants/regressions to lock in). For OS/Accessibility-heavy changes, prefer a short manual verification checklist.
- For changes touching behavior covered in `TEST-REGRESSIONS.md`, Agent should read those entries before editing and update/add an entry when fixing a new regression.
- When adding, removing, or changing a timer/delay mechanism in the code, update `SPECIFICATION-TIMERS.md` to match.
- Agent should prefer each code file to have a single responsibility ensuring that code files don't get too large. Each code file should have a concise description header of its responsibility that is maintained up to date
- IMPORTANT: The code should be as elegant and clean as possible. So when implementing a new feature, think deeply about possibly restructuring the code if this would help more cleanly implement the feature and similar features. Code reuse and simplicity are VERY important. We also do not want to "over-engineer" at the cost of significant increased complexity.
- Agent should NOT worry about preserving backward compatibility

## Rules for Codex ONLY (Claude ignores this whole section)

Elevated privileges (IMPORTANT!):

- If running `swift build` or other commands gives a sandbox error, ask me for approval to run with elevated privileges.
- If you encounter path errors, the path should be correct in zsh (rather than bash).
- Tools requiring accessibility APIs should also be run with elevated privileges in zsh. Without it, tools like `winmanmon` will misleadingly err saying "Please grant accessibility access in System Preferences". Note: `winmanmon` is in the zsh path.

Other:

- Codex's commit messages should be relatively detailed, typically at least a few lines long
