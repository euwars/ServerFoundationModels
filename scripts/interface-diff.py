#!/usr/bin/env python3
"""Signature-level parity gate.

Compares Apple's FoundationModels .swiftinterface against ServerFoundationModels's
emitted .swiftinterface, declaration by declaration, with normalized
signatures (module qualifiers, attributes, availability, and cosmetic
modifiers stripped). Reports:
  - Apple declarations missing from ServerFoundationModels (parity gaps)
  - declarations whose normalized signature differs

Usage: interface-diff.py <apple.swiftinterface> <ours.swiftinterface>
Exit 1 if any unallowlisted gap exists.
"""

import re
import sys
from collections import defaultdict

APPLE, OURS = sys.argv[1], sys.argv[2]

# Justified divergences, each with a reason. Keep this list short and honest.
ALLOWLIST_PATTERNS = [
    # Apple-OS-bound runtime surfaces we expose but back differently:
    r"^SystemLanguageModel\.Adapter\b.*",          # FM-backed off-macOS; throws elsewhere
    r"^Transcript\.ImageAttachment\b.*pixelBuffer", # var vs throwing func returning CVReadOnlyPixelBuffer
    r"^GenerationGuide\b.*pattern",                 # Regex source not extractable; advisory
    # @Generable macro expansion: nested PartiallyGenerated struct + members only
    r"^struct \w+\.PartiallyGenerated$",
    r"^[\w.]+\.PartiallyGenerated\.var id: GenerationID$",
    r"^[\w.]+\.PartiallyGenerated\.var \w+: [\w.]+\.PartiallyGenerated\?$",
    r"^[\w.]+\.PartiallyGenerated\.init \(_ generatedContent: GeneratedContent\) throws$",
    r"^Transcript\.Segment\.custom\b.*",            # existential spelling differs in emission
    # Apple-graphics-typed API (CGImage/CIImage/CVPixelBuffer) does not exist
    # off Apple platforms — matching FoundationModels itself.
    r".*\b(CGImage|CIImage|CVPixelBuffer|CGImagePropertyOrientation|ciImage|pixelBuffer)\b.*",
    r".*Locale\.Language.*",                        # Locale.Language parity is Darwin-typed
]

COSMETIC = [
    r"@available\([^)]*\)", r"@_alwaysEmitIntoClient", r"@_disfavoredOverload",
    r"@frozen", r"@_hasMissingDesignatedInitializers", r"@discardableResult",
    r"@inline\(__always\)", r"@_documentation\([^)]*\)", r"@objc",
    r"@_implements\([^)]*\)", r"@attached\([^)]*\)", r"@resultBuilder",
    r"@_functionBuilder", r"@propertyWrapper", r"@_spi\([^)]*\)",
    r"\bnonisolated\(nonsending\)\s*", r"\bnonisolated\s+", r"@concurrent\s*",
    r"\bfinal\s+", r"\bconvenience\s+", r"\bindirect\s+",
    r"\bsending\s+", r"@_inheritActorContext\s*", r"@isolated\(any\)\s*",
    r"@escaping\s+", r"\bsome\s+", r"\bany\s+",
]


def normalize(line):
    line = re.sub(r"\b[A-Za-z_][\w]*::", "", line)          # Module:: qualifiers
    line = re.sub(r"\b(FoundationModels|ServerFoundationModels|Swift|FoundationEssentials|FoundationNetworking|FoundationInternationalization|Foundation|CoreGraphics|CoreImage|CoreVideo|ImageIO|Observation|_Concurrency|_StringProcessing|Darwin|CoreFoundation)\.", "", line)
    for pattern in COSMETIC:
        line = re.sub(pattern, "", line)
    line = re.sub(r"\b(consuming|borrowing|isolated|mutating|nonmutating)\s+", "", line)
    line = re.sub(r"\s+", " ", line).strip()
    # Default-value expressions vary in rendering; compare presence only.
    # (Paren-aware so `= GenerationOptions()` parses; careful not to eat
    # `==` operators or where-clause same-type constraints.)
    line = re.sub(r"(?<![=!<>~])= (?!=)(?:[^,()]|\([^()]*\))+", "= <default> ", line)
    # Internal parameter names don't affect the API: `label internal:` -> `label:`.
    line = re.sub(r"([(,]\s*)([a-zA-Z_]\w*) [a-zA-Z_]\w*(\s*:)", r"\1\2\3", line)
    # Subscript parameter names are internal-only.
    line = re.sub(r"subscript\((\w+):", "subscript(_:", line)
    # Read-only `var` and `let` are the same API surface.
    line = re.sub(r"\b(static )?let ", r"\1var ", line)
    # Collection Index typealias rendering.
    line = line.replace("Transcript.Index", "Int")
    # Executor.Model typealias rendering.
    line = re.sub(r"(\w+)\.Executor\.Model", r"\1", line)
    # Protocol-composition member order is not semantic.
    line = re.sub(
        r"((?:[A-Za-z_][\w.]* & )+[A-Za-z_][\w.]*)",
        lambda m: " & ".join(sorted(m.group(1).split(" & "))),
        line,
    )
    line = re.sub(r"\s+", " ", line).strip()
    return line


DECL = re.compile(
    r"^(?:public|open)\b.*?\b(struct|class|enum|protocol|actor|func|var|let|init|case|subscript|typealias|associatedtype|macro)\b"
)
TYPE_DECL = re.compile(r"\b(struct|class|enum|protocol|actor|extension)\s+([A-Za-z_][\w.]*)")


def parse(path):
    decls = defaultdict(set)
    stack = []
    depth = 0
    for raw in open(path):
        stripped = raw.strip()
        if not stripped or stripped.startswith("//") or stripped.startswith("#"):
            continue
        opens, closes = raw.count("{"), raw.count("}")
        is_public = stripped.startswith(("public", "open", "final public", "extension", "@", "convenience public", "nonisolated public", "indirect public"))
        line = normalize(stripped)
        normalized = line

        type_match = TYPE_DECL.search(line)

        if type_match and is_public:
            kind, name = type_match.groups()
            name = normalize(name)
            if kind == "extension":
                path_now = name
            else:
                parent = stack[-1][0] if stack else ""
                path_now = f"{parent}.{name}" if parent else name
                if not name.startswith("_"):
                    decls[""].add(f"{kind} {path_now}")
            if opens > closes:
                stack.append((path_now, depth))
            depth += opens - closes
            continue

        decl = DECL.search(line)
        if decl and "public" in line:
            holder = stack[-1][0] if stack else ""
            sig = normalized.removeprefix("public ").strip()
            sig = re.sub(r"\s*\{.*$", "", sig)
            if not re.search(r"\b__|\b_[A-Z]", sig) and "deinit" not in sig:
                # Accessor noise
                if sig not in ("get", "set", "_modify", "get async throws") and "func == (" not in sig and "func != (" not in sig:
                    decls[holder].add(sig)
        elif stack and re.match(r"(?:indirect\s+)?case\s+[A-Za-z_]", line):
            # Enum cases inherit their enum's access level, so swiftinterface
            # emits them WITHOUT `public` — the branch above never sees them.
            # (This blind spot let the beta-3 SamplingMode.Kind case renames
            # through the gate.) `case .x` pattern-match lines in inlined
            # @export(implementation) bodies don't match: identifier required.
            holder = stack[-1][0] if stack else ""
            sig = re.sub(r"\s*\{.*$", "", line).strip()
            decls[holder].add(sig)

        if opens > closes:
            inner = TYPE_DECL.search(line)
            name = None
            if inner:
                parent = stack[-1][0] if stack else ""
                nm = normalize(inner.group(2))
                name = f"{parent}.{nm}" if parent and inner.group(1) != "extension" else nm
            stack.append((name or (stack[-1][0] if stack else ""), depth))
        depth += opens - closes
        while stack and depth <= stack[-1][1]:
            stack.pop()
    return decls


apple = parse(APPLE)
ours = parse(OURS)

ours_all = set()
for holder, sigs in ours.items():
    for sig in sigs:
        ours_all.add((holder, sig))


def allowed(holder, sig):
    key = f"{holder}.{sig}" if holder else sig
    return any(re.search(pattern, key) for pattern in ALLOWLIST_PATTERNS)


gaps = []
for holder, sigs in sorted(apple.items()):
    if holder.startswith("_") or ".._" in holder:
        continue
    for sig in sorted(sigs):
        if (holder, sig) in ours_all:
            continue
        # Tolerate the same signature appearing under a related holder:
        # extension members and protocol-extension defaults get attributed
        # differently between the two emitters.
        if any(sig in member_set for member_set in ours.values()):
            continue
        if allowed(holder, sig):
            continue
        gaps.append((holder, sig))

print(f"Apple declarations checked: {sum(len(v) for v in apple.values())}")
print(f"Signature-level gaps: {len(gaps)}")
for holder, sig in gaps:
    print(f"  [{holder or '<top>'}] {sig}")
sys.exit(1 if gaps else 0)
