"""Inventory UI source surfaces and explicit color/accessibility candidates.

This is a source inventory, not a claim that device scenarios passed.
Run from the repository root. Output belongs to the local audit directory.
"""
import csv
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'audit/2026-10-31/interface-beta'
OUT.mkdir(parents=True, exist_ok=True)


def tokens(source):
    pattern = r'''//[^\n]*|/\*[\s\S]*?\*/|r?(?:"""[\s\S]*?"""|\x27\x27\x27[\s\S]*?\x27\x27\x27|"(?:\\.|[^"\\])*"|\x27(?:\\.|[^\x27\\])*\x27)|[a-zA-Z_$][\w$]*|[^\s]'''
    return [(m.group(), m.start(), m.end()) for m in re.finditer(pattern, source)]


def calls(source):
    stack, result = [], []
    code = [t for t in tokens(source) if not t[0].startswith(('//', '/*'))]
    for i, (token, start, end) in enumerate(code):
        if token in ('(', '[', '{'):
            name = code[i-1][0] if i else ''
            const = code[i-2][1] if i > 1 and code[i-2][0] == 'const' else None
            if token == '[' and name == 'const':
                const = code[i-1][1]
            stack.append((start, name, const))
        elif token in (')', ']', '}') and stack:
            begin, name, const = stack.pop()
            result.append((begin, end, name, const))
    return result


def inventory():
    rows = []
    for path in sorted((ROOT / 'lib').rglob('*.dart')):
        source = path.read_text(encoding='utf-8-sig')
        if 'package:flutter/material.dart' not in source and 'part of' not in source:
            continue
        surfaces = re.findall(r'\b(Scaffold|showModalBottomSheet|showDialog|PopupMenuButton|SimpleDialog|AlertDialog)\b', source)
        labels = re.findall(r"(?:title|labelText|hintText|tooltip):\s*(?:const\s+)?(?:Text\()?\s*'([^'\n]*)'", source)
        explicit = len(re.findall(r'Colors\.(?:white|black|grey)|Color\(0x', source))
        icon_calls = [source[a:b] for a,b,n,_ in calls(source) if n == 'IconButton']
        missing = sum('tooltip:' not in call for call in icon_calls)
        rows.append(dict(path=path.relative_to(ROOT).as_posix(), surfaces=len(surfaces), labels=labels,
                         explicit_color_candidates=explicit, icon_buttons_without_tooltip=missing,
                         lines=len(source.splitlines())))
    (OUT/'source-inventory.json').write_text(json.dumps(rows, ensure_ascii=False, indent=2), encoding='utf-8')
    lines = ['# Source interface inventory', '', 'Source inspection only; visual and device coverage must be tracked separately.', '']
    for row in rows:
        lines += [f"## {row['path']} ({row['lines']} lines)",
                  f"Surfaces: {row['surfaces']}; explicit colors: {row['explicit_color_candidates']}; unlabeled icon buttons: {row['icon_buttons_without_tooltip']}",
                  ' | '.join(row['labels']), '']
    (OUT/'source-inventory.md').write_text('\n'.join(lines), encoding='utf-8')
    print(f"Indexed {len(rows)} UI source files; {sum(r['surfaces'] for r in rows)} surface declarations; {sum(r['icon_buttons_without_tooltip'] for r in rows)} icon buttons need review")


if __name__ == '__main__':
    inventory()
