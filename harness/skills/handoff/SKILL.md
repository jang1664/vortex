---
name: handoff
description: Use when generating a self-contained Vortex task handoff from agent-tasks STATUS.yaml files and current worktree context.
---

# Handoff

Generate a handoff document, then guide the user through `/clear` and resume.

## Usage

```
/handoff              # auto-detect task from agent-tasks/**/STATUS.yaml
/handoff port-scale   # specify root task
/handoff port-scale/dma-debug  # specify subtask path
```

## Step 1: Determine Task Name

- If an argument is provided, use it as `<task_path>` (supports slash-separated subtask paths).
- If no argument, scan `agent-tasks/` recursively for STATUS.yaml files. Display them as a tree. If exactly one root task exists, use it. If multiple exist, ask the user which one.

## Step 2: Gather Context

Collect the following information to write the handoff:

1. **Current progress** — Read `agent-tasks/<task_name>/STATUS.yaml` (includes iteration logs). Summarize what has been done.
2. **Key decisions made** — Extract important design/implementation decisions from the conversation and logs.
3. **Remaining work** — What still needs to be done. Be specific: file paths, commands, configs.
4. **Gotchas** — Pitfalls, workarounds, environment issues encountered. These save the next session from repeating mistakes.
5. **Reference files** — List all relevant spec docs, log files, test plans, and skill files.

## Step 3: Write Handoff File

Generate the filename with current datetime:

```bash
HANDOFF_FILE="agent-tasks/<task_name>/handoff.$(date +%Y%m%d-%H%M).md"
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
Handoff saved to: agent-tasks/<task_name>/handoff.<datetime>.md

Please run `/clear`, then start the new session with:

@agent-tasks/<task_name>/handoff.<datetime>.md 를 읽고 다시 시작해줘.
```

## Rules

- Do NOT run `/clear` yourself — only the user can do this.
- The handoff must be **self-contained** — a fresh session reading only this file should have full context to continue.
- Include exact commands (with CONFIGS, env vars, etc.) for any pending test runs.
- If there are uncommitted RTL changes, note which files are modified (use `git status`).
- Keep the handoff concise but complete. Target 50-100 lines.
