#!/usr/bin/env python3
"""
Pre-tool hook: blocks direct Read access to tools/hw_draw/*.json files.
Use `python3 tools/hw_draw/hw_tool.py` instead.

Reads CLAUDE_TOOL_INPUT from stdin (JSON with file_path).
Exits 2 to block the tool call with a message.
"""
import json
import sys
import os


def main():
    try:
        tool_input = json.loads(sys.stdin.read())
    except (json.JSONDecodeError, EOFError):
        sys.exit(0)

    file_path = tool_input.get("file_path", "")

    # Normalize to check against tools/hw_draw/
    normalized = os.path.normpath(file_path)

    if "tools/hw_draw" in normalized and normalized.endswith(".json"):
        print(
            "BLOCKED: Do not read tools/hw_draw/*.json directly. "
            "Use `python3 tools/hw_draw/hw_tool.py --file <path> show` instead."
        )
        sys.exit(2)

    sys.exit(0)


if __name__ == "__main__":
    main()
