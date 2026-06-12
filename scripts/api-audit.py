#!/usr/bin/env python3
"""API parity audit: Apple FoundationModels (SDK 27 swiftinterface) vs LinuxFoundation sources.

Extracts public declarations from both sides, normalized to:
    TypePath                      (types, protocols, macros)
    TypePath.memberName           (funcs/vars/inits/cases, name-level)
Then reports what Apple ships that LinuxFoundation lacks.
"""

import re
import sys
import glob
from collections import defaultdict

IFACE = "reference/FoundationModels-macOS27.swiftinterface"
OUR_SOURCES = glob.glob("Sources/LinuxFoundation/*.swift")

TYPE_KINDS = r"(?:struct|class|enum|protocol|actor)"
MEMBER_KINDS = r"(?:func|var|let|init|case|subscript|typealias|associatedtype|macro)"


def clean(line: str) -> str:
    # strip module qualifications: FoundationModels::, Swift::, Foundation:: etc
    line = re.sub(r"\b\w+::", "", line)
    return line


def parse(lines, is_interface):
    """Walk braces; collect (path, kind, name) for public decls."""
    decls = set()
    stack = []  # (name_or_None, depth_at_open)
    depth = 0
    ext_target = None

    for raw in lines:
        line = clean(raw.rstrip())
        stripped = line.strip()
        if not stripped or stripped.startswith("//"):
            depth += line.count("{") - line.count("}")
            continue

        opens = line.count("{")
        closes = line.count("}")

        is_public = bool(re.search(r"\bpublic\b", stripped)) and not stripped.startswith("@_spi")
        # extension target tracking
        m = re.match(r"^extension\s+([\w.]+)", stripped)
        if m and depth == 0:
            ext_target = m.group(1)
            if opens > closes:
                stack.append(("<ext:%s>" % ext_target, depth))
            depth += opens - closes
            continue

        if is_public:
            path_parts = []
            for name, _ in stack:
                if name and name.startswith("<ext:"):
                    path_parts = name[5:-1].split(".")
                elif name:
                    path_parts.append(name)
            # type decl?
            tm = re.search(r"\b" + TYPE_KINDS + r"\s+([A-Za-z_][\w]*)", stripped)
            mm = re.search(
                r"\b(func|var|let|init|case|subscript|associatedtype|macro)\s*([A-Za-z_][\w]*)?",
                stripped,
            )
            if tm and re.search(r"\b(?:public|open)\b[^=]*\b" + TYPE_KINDS + r"\b", stripped):
                name = tm.group(1)
                path = ".".join(path_parts + [name])
                if not name.startswith("_"):
                    decls.add(("type", path))
                if opens > closes:
                    stack.append((name, depth))
                depth += opens - closes
                continue
            elif mm and path_parts:
                kind, name = mm.group(1), mm.group(2)
                if kind == "init":
                    name = "init"
                if name and not name.startswith("_") and not path_parts[0].startswith("_"):
                    decls.add(("member", ".".join(path_parts) + "." + name))
            elif mm and not path_parts:
                kind, name = mm.group(1), mm.group(2)
                if kind == "macro" and name:
                    decls.add(("type", "@" + name))
                elif name and not name.startswith("_"):
                    decls.add(("member", name))

        # general nesting for non-public or non-type lines
        tm2 = re.search(r"\b" + TYPE_KINDS + r"\s+([A-Za-z_][\w]*)", stripped)
        if opens > closes:
            stack.append((tm2.group(1) if tm2 else None, depth))
        depth += opens - closes
        while stack and depth <= stack[-1][1]:
            stack.pop()
    return decls


apple = parse(open(IFACE).readlines(), True)
ours = set()
for path in OUR_SOURCES:
    ours |= parse(open(path).readlines(), False)
# our macros live in Macros.swift as `public macro X`
ours_names = {p for _, p in ours}

apple_types = sorted(p for k, p in apple if k == "type")
apple_members = sorted(p for k, p in apple if k == "member")

missing_types = [t for t in apple_types if t not in ours_names]
present_types = [t for t in apple_types if t in ours_names]

# member-level: only for types we already have
present_set = set(present_types)
missing_members = []
for m in apple_members:
    holder = m.rsplit(".", 1)[0]
    if holder in present_set or holder.split(".")[0] in present_set:
        if m not in ours_names:
            missing_members.append(m)

print(f"Apple public types/macros: {len(apple_types)}")
print(f"  present in LinuxFoundation: {len(present_types)}")
print(f"  MISSING types: {len(missing_types)}")
for t in missing_types:
    print(f"    - {t}")
print(f"\nApple public members on types we have: checked {len(apple_members)}")
print(f"  MISSING members (name-level): {len(missing_members)}")
for m in sorted(set(missing_members)):
    print(f"    - {m}")
