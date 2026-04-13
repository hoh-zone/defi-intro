#!/usr/bin/env python3
"""Convert `module pkg::mod { ... }` to braceless `module pkg::mod;` in ```move``` blocks."""
from __future__ import annotations

import re
import sys
from pathlib import Path


def brace_delta(line: str) -> int:
    if "//" in line:
        line = line.split("//", 1)[0]
    return line.count("{") - line.count("}")


MODULE_LINE = re.compile(r"^(\s*)module\s+([a-zA-Z0-9_:]+)\s*\{\s*$")


def strip_one_module_block(lines: list[str], start: int) -> tuple[list[str], int]:
    """If lines[start] is `module ... {`, emit braceless module and body; return (new_lines, next_index)."""
    m = MODULE_LINE.match(lines[start])
    if not m:
        return [], start
    indent, name = m.group(1), m.group(2)
    out: list[str] = [f"{indent}module {name};"]
    i = start + 1
    depth = 1
    while i < len(lines):
        line = lines[i]
        d = brace_delta(line)
        new_depth = depth + d
        if new_depth == 0:
            # Closing brace(s) of module — drop this line if it only closes the module.
            if line.strip() == "}":
                i += 1
                break
            # Rare: trailing content after `}` on same line
            stripped = line.rstrip()
            if stripped.endswith("}"):
                rest = stripped[:-1].rstrip()
                if rest and not rest.endswith("{"):
                    out.append(rest)
            i += 1
            break
        out.append(line)
        depth = new_depth
        i += 1
    return out, i


def transform_move_block(block: str) -> str:
    lines = block.split("\n")
    result: list[str] = []
    i = 0
    while i < len(lines):
        chunk, j = strip_one_module_block(lines, i)
        if chunk:
            result.extend(chunk)
            i = j
        else:
            result.append(lines[i])
            i += 1
    return "\n".join(result)


MOVE_FENCE = re.compile(r"(```move\n)(.*?)(```)", re.DOTALL)


def process_file(path: Path) -> bool:
    text = path.read_text(encoding="utf-8")
    changed = False

    def repl(m: re.Match[str]) -> str:
        nonlocal changed
        before, body, after = m.group(1), m.group(2), m.group(3)
        new_body = transform_move_block(body)
        if new_body != body:
            changed = True
        return before + new_body + after

    new_text = MOVE_FENCE.sub(repl, text)
    if changed:
        path.write_text(new_text, encoding="utf-8")
    return changed


def main() -> None:
    roots = [Path(sys.argv[1])] if len(sys.argv) > 1 else [Path("src")]
    paths: list[Path] = []
    for root in roots:
        if root.is_file() and root.suffix == ".md":
            paths.append(root)
        else:
            paths.extend(sorted(root.rglob("*.md")))
    n = 0
    for p in paths:
        if any(x in p.parts for x in (".git", "node_modules", "build", "target")):
            continue
        try:
            if process_file(p):
                print(p)
                n += 1
        except Exception as e:
            print(f"ERR {p}: {e}", file=sys.stderr)
            sys.exit(1)
    print(f"updated {n} files", file=sys.stderr)


if __name__ == "__main__":
    main()
