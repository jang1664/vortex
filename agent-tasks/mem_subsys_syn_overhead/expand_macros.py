"""Hand-expand BUFFER / POP_COUNT / REDUCE_TREE / NEG_EDGE macros in-place.

Synopsys DC chokes on Vortex's `__LINE__`-concatenated macro instance names
(VX_define.vh ~line 198/220 — `\`\`\`__LINE__` triple-tick concat). Rather
than patch the upstream macros, we walk each .sv file in the preproc dir and
substitute every `\`BUFFER(...)`, `\`POP_COUNT(...)`, `\`REDUCE_TREE(...)`,
`\`NEG_EDGE(...)` call with its literal module instantiation, using a
per-file line number for the instance name.

Run after gen_sources.sh produces the preproc/ folder, before SynthConfig
analyzes it.
"""

from __future__ import annotations

import argparse
import re
from pathlib import Path

# Match the macro invocation. Allow whitespace and arbitrary args.
# These macros take comma-separated SV expressions (which may themselves
# contain parens) so we balance parens to find the closing one.

CALL_RE = re.compile(r"`(BUFFER|BUFFER_EX|POP_COUNT|POP_COUNT_EX|REDUCE_TREE|NEG_EDGE)\s*\(")


def _split_args(s: str) -> list[str]:
    """Split a comma-separated SV arg list, respecting paren/bracket nesting."""
    args, depth, cur = [], 0, []
    for ch in s:
        if ch == "(" or ch == "{" or ch == "[":
            depth += 1
            cur.append(ch)
        elif ch == ")" or ch == "}" or ch == "]":
            depth -= 1
            cur.append(ch)
        elif ch == "," and depth == 0:
            args.append("".join(cur).strip())
            cur = []
        else:
            cur.append(ch)
    if cur:
        args.append("".join(cur).strip())
    return args


def _expand_one(name: str, args: list[str], lineno: int) -> str:
    """Return the inline expansion of one macro call."""
    tag = f"__{name.lower()}_{lineno}"
    if name == "BUFFER":
        dst, src = args
        return (f"VX_pipe_register #("
                f".DATAW($bits({dst})), .RESETW($bits({dst})), .DEPTH(1)) "
                f"{tag} (.clk(clk), .reset(reset), .enable(1'b1), "
                f".data_in({src}), .data_out({dst}))")
    if name == "BUFFER_EX":
        dst, src, ena, resetw, latency = args
        return (f"VX_pipe_register #("
                f".DATAW($bits({dst})), .RESETW({resetw}), .DEPTH({latency})) "
                f"{tag} (.clk(clk), .reset(reset), .enable({ena}), "
                f".data_in({src}), .data_out({dst}))")
    if name == "POP_COUNT":
        out, in_ = args
        return (f"VX_popcount #(.N($bits({in_})), .MODEL(1)) "
                f"{tag} (.data_in({in_}), .data_out({out}))")
    if name == "POP_COUNT_EX":
        out, in_, model = args
        return (f"VX_popcount #(.N($bits({in_})), .MODEL({model})) "
                f"{tag} (.data_in({in_}), .data_out({out}))")
    if name == "REDUCE_TREE":
        op, out, in_, n, outw, inw = args
        return (f"VX_reduce_tree #(.IN_W({inw}), .OUT_W({outw}), "
                f".N({n}), .OP({op})) "
                f"{tag} (.data_in({in_}), .data_out({out}))")
    if name == "NEG_EDGE":
        dst, src = args
        return (f"VX_edge_trigger #(.POS(0), .INIT(0)) "
                f"{tag} (.clk(clk), .reset(reset), .data_in({src}), .data_out({dst}))")
    raise RuntimeError(f"unhandled macro: {name}")


def _find_balanced_paren(text: str, start: int) -> int:
    """Given index of '(', return index of matching ')' (or -1)."""
    depth = 0
    in_str = False
    in_line_comment = False
    in_block_comment = False
    i = start
    while i < len(text):
        ch = text[i]
        nxt = text[i+1] if i+1 < len(text) else ""
        if in_line_comment:
            if ch == "\n":
                in_line_comment = False
        elif in_block_comment:
            if ch == "*" and nxt == "/":
                in_block_comment = False
                i += 1
        elif in_str:
            if ch == '"' and text[i-1] != "\\":
                in_str = False
        else:
            if ch == "/" and nxt == "/":
                in_line_comment = True
                i += 1
            elif ch == "/" and nxt == "*":
                in_block_comment = True
                i += 1
            elif ch == '"':
                in_str = True
            elif ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if depth == 0:
                    return i
        i += 1
    return -1


def expand_file(path: Path) -> int:
    """Edit `path` in place. Return number of macros expanded."""
    text = path.read_text(errors="ignore")
    # Build a line-number index so we can map char offsets → line numbers.
    line_starts = [0]
    for i, ch in enumerate(text):
        if ch == "\n":
            line_starts.append(i + 1)

    def lineno_at(offset: int) -> int:
        # Binary search would be faster, but linear is fine.
        n = 1
        for ls in line_starts:
            if ls > offset:
                return n - 1
            n += 1
        return n - 1

    out_chunks = []
    cursor = 0
    count = 0
    for m in CALL_RE.finditer(text):
        name = m.group(1)
        open_paren = m.end() - 1
        close_paren = _find_balanced_paren(text, open_paren)
        if close_paren == -1:
            # Malformed — keep original
            continue
        arg_str = text[open_paren + 1:close_paren]
        args = _split_args(arg_str)
        try:
            replacement = _expand_one(name, args, lineno_at(m.start()))
        except (ValueError, RuntimeError):
            # Wrong arg count — leave alone
            continue
        # emit text up to macro start
        out_chunks.append(text[cursor:m.start()])
        out_chunks.append(replacement)
        cursor = close_paren + 1
        count += 1
    if count == 0:
        return 0
    out_chunks.append(text[cursor:])
    path.write_text("".join(out_chunks))
    return count


def expand_dir(preproc_dir: Path) -> int:
    total = 0
    for sv in sorted(preproc_dir.glob("*.sv")):
        n = expand_file(sv)
        if n:
            print(f"[expand] {sv.name}: {n} macro call(s) expanded")
            total += n
    return total


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("preproc_dir", type=Path)
    args = ap.parse_args()
    total = expand_dir(args.preproc_dir)
    print(f"[expand] total: {total} macro call(s) expanded")
