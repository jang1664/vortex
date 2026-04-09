# Handoff

Generate a handoff document, then guide the user through `/clear` and resume.

## Usage

```
/handoff              # auto-detect task from docs/*/STATUS.yaml
/handoff rtl-improve  # specify task name explicitly
```

## Step 1: Determine Task Name

- If an argument is provided, use it as `<task_name>`.
- If no argument, scan `docs/*/STATUS.yaml` for existing task directories. If exactly one exists, use it. If multiple exist, ask the user which one. If none exist, ask the user to provide a task name.

## Step 2: Gather Context

Collect the following information to write the handoff:

1. **Current progress** — Read `docs/<task_name>/STATUS.yaml` (includes iteration logs). Summarize what has been done.
2. **Key decisions made** — Extract important design/implementation decisions from the conversation and logs.
3. **Remaining work** — What still needs to be done. Be specific: file paths, commands, configs.
4. **Gotchas** — Pitfalls, workarounds, environment issues encountered. These save the next session from repeating mistakes.
5. **Reference files** — List all relevant spec docs, log files, test plans, and skill files.

## Step 3: Write Handoff File

Generate the filename with current datetime:

```bash
HANDOFF_FILE="docs/<task_name>/handoff.$(date +%Y%m%d-%H%M).md"
```

Write the handoff document with this structure:

```markdown
# <Task Name> Handoff — <YYYY-MM-DD>

## Current Progress
<Summarize completed work, with file paths and status>

## Key Decisions Made
<Numbered list of important decisions and their rationale>

## Remaining Work
<Numbered list with specific details: commands, file paths, configs>

## Gotchas
<Bulleted list of pitfalls and workarounds>

## Reference Files
<Bulleted list of relevant files with descriptions>
```

## Step 4: Instruct User

After writing the handoff file, output the following message **exactly** (replacing the path):

```
Handoff saved to: docs/<task_name>/handoff.<datetime>.md

Please run `/clear`, then start the new session with:

@docs/<task_name>/handoff.<datetime>.md 를 읽고 다시 시작해줘.
```

## Rules

- Do NOT run `/clear` yourself — only the user can do this.
- The handoff must be **self-contained** — a fresh session reading only this file should have full context to continue.
- Include exact commands (with CONFIGS, env vars, etc.) for any pending test runs.
- If there are uncommitted RTL changes, note which files are modified (use `git status`).
- Keep the handoff concise but complete. Target 50-100 lines.
