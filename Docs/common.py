# -*- coding: utf-8 -*-
"""Turn start-only block lists into contiguous (start, end) ranges and pull the
real source lines out of the script files, so the document can never show code
that differs from what is in the repository."""
import html, pathlib

SCRIPTS = pathlib.Path("/home/user/SolarWinds/Scripts")


def resolve(blocks, filename):
    """blocks: [(start, title, explanation), ...] -> [(start, end, title, expl, code)]"""
    path = SCRIPTS / filename
    lines = path.read_text(encoding="utf-8").split("\n")
    while lines and lines[-1] == "":
        lines.pop()
    total = len(lines)

    starts = [b[0] for b in blocks]
    if starts != sorted(starts):
        raise SystemExit(f"{filename}: block starts are not in ascending order")
    if starts[0] != 1:
        raise SystemExit(f"{filename}: first block must start at line 1, got {starts[0]}")

    out = []
    for i, (start, title, expl) in enumerate(blocks):
        end = (starts[i + 1] - 1) if i + 1 < len(blocks) else total
        code = "\n".join(lines[start - 1:end])
        out.append((start, end, title, expl, code))

    # prove every line of the file landed in exactly one block
    seen = set()
    for start, end, *_ in out:
        for n in range(start, end + 1):
            if n in seen:
                raise SystemExit(f"{filename}: line {n} is in two blocks")
            seen.add(n)
    missing = [n for n in range(1, total + 1) if n not in seen]
    if missing:
        raise SystemExit(f"{filename}: lines not covered: {missing}")

    return out, total


def code_html(code):
    """One element per source line. A line that is too wide to fit then wraps
    with a hanging indent, so the continuation reads as part of the same line
    instead of looking like a new statement at column zero."""
    return "".join(
        f'<span class="cl">{html.escape(line) if line else "&nbsp;"}</span>'
        for line in code.split("\n")
    )
