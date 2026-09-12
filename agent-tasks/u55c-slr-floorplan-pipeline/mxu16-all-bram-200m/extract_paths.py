#!/usr/bin/env python3
"""Extract setup-path summaries without loading a full timing report at once."""
import json
import re
import sys

def paths(filename):
    block = []
    start = 0
    with open(filename) as stream:
        for number, line in enumerate(stream, 1):
            if line.startswith("Slack ("):
                if block:
                    yield start, block
                start, block = number, [line.rstrip()]
            elif block:
                block.append(line.rstrip())
        if block:
            yield start, block

if __name__ == "__main__":
    result = []
    for number, block in paths(sys.argv[1]):
        fields = {}
        for line in block[:22]:
            match = re.match(r"  ([A-Za-z ]+):\s+(.*)", line)
            if match:
                fields[match[1].strip()] = match[2]
        if not fields.get("Path Type", "").startswith("Setup"):
            continue
        result.append(dict(line=number, slack=float(re.search(r":\s+([-\d.]+)ns", block[0])[1]), **fields))
    result.sort(key=lambda row: row["slack"])
    print(json.dumps(result, indent=2))
