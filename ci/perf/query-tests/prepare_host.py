from pathlib import Path
p = Path("android/Compat/Package.swift")
s = p.read_text()
begin = s.index('        .macro(\n            name: "FoundationMacros"')
end = s.index('        .macro(\n            name: "PortableDataMacros"', begin)
block = s[begin:end].replace('name: "FoundationMacros"', 'name: "PortableFoundationMacros"')
block = block.replace('            exclude: ["VENDORED.md"],', '            path: "Sources/FoundationMacros",\n            exclude: ["VENDORED.md"],')
assert 'path: "Sources/FoundationMacros"' in block
s = s[:begin] + block + s[end:]
s = s.replace('.target(name: "FoundationMacros", condition:', '.target(name: "PortableFoundationMacros", condition:')
s = s.replace('"602.0.0" ..< "605.0.0"', 'exact: "602.0.0"')
p.write_text(s)
print("Host-only macro renamed to avoid shadowing Apple Foundation; production SwiftSyntax602 pin selected")
