# Commit Repo

Smart multi-commit tool. Groups related changes into separate meaningful commits with detailed messages.

## Steps

1. **Gather state** — Run `git status`, `git diff` (staged and unstaged), and `git log --oneline -10` in parallel to understand all pending changes and recent commit style.

2. **Analyze changes** — Review every modified, added, and untracked file. Classify each change by:
   - **Area**: which subsystem / directory it belongs to (e.g., RTL, testbench, tools, harness, docs)
   - **Intent**: what the change accomplishes (bug fix, new feature, refactor, debug logging, etc.)
   - **Dependency**: whether changes must be committed together or can stand alone

3. **Group into commits** — Cluster related changes into logical commit units. Each group should represent one coherent change. Ordering matters: foundational changes (e.g., interface updates) should come before dependent changes (e.g., consumers of that interface). Typical groupings:

   - One commit per subsystem or module touched
   - Separate bug fixes from feature additions
   - Separate RTL changes from test/harness changes
   - Separate tooling / infrastructure changes from functional changes
   - If only one logical change exists, a single commit is fine

4. **Present the plan** — Display the proposed commit plan to the user:
   ```
   Commit 1: <short summary>
     Files: file1.sv, file2.sv
     Message: <detailed message>

   Commit 2: <short summary>
     Files: file3.py, file4.py
     Message: <detailed message>
   ```

   Ask the user for approval before proceeding.

5. **Execute commits** — For each planned commit:
   a. `git add` only the files for that commit
   b. Create the commit with a detailed message using this format:

   ```
   <type>(<scope>): <short summary>

   <Detailed explanation of what changed and why. Include:
   - What problem existed or what feature was needed
   - What was changed and how it solves the problem
   - Any important design decisions or trade-offs
   - References to relevant specs, issues, or discussions>

   Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
   ```

   Use conventional commit types: `feat`, `fix`, `refactor`, `test`, `docs`, `chore`, `style`, `perf`.

6. **Verify** — After all commits, run `git log --oneline -N` (N = number of new commits) and `git status` to confirm clean state.

## Rules

- **Never commit sensitive files** — Check for `.env`, credentials, keys, or secret files. Warn the user if any are staged.
- **Never force-push** — Only create new commits.
- **Never use `--no-verify`** — If a pre-commit hook fails, investigate and fix the issue.
- **Preserve file state** — If a file needs to be split across commits (partial staging), use `git add -p` with explicit hunks. If partial staging is too complex, ask the user how to proceed.
- **Detailed messages** — Commit messages should be thorough. The body should explain the "why" not just the "what". A future reader should understand the motivation without reading the diff.
- **No empty commits** — Skip any planned commit that would have no files.
- **Respect `.gitignore`** — Do not add files that are gitignored.
