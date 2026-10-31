import ast
import json
import subprocess
import sys
from pathlib import Path


def verify_unvendored(actual, approved, vendors):
    names = {name.lower() for name in vendors}
    def locked(pins):
        return {pin["identity"].lower(): pin["state"] for pin in pins if pin["identity"].lower() not in names}
    assert locked(actual) == locked(approved), "Unpatched dependencies differ from the approved lock"


def main():
    stage = Path(sys.argv[1])
    tool = Path(sys.argv[2]).resolve()
    tree = ast.parse(tool.read_text())
    vendors = next(ast.literal_eval(node.value) for node in tree.body if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == "VENDORED" for t in node.targets))
    actual = json.loads((stage / "Package.resolved").read_text())["pins"]
    approved = json.loads((tool.parents[1] / "app/Package.resolved").read_text())["pins"]
    verify_unvendored(actual, approved, vendors)
    pins = {pin["identity"].lower(): pin["state"] for pin in actual}
    for name, (_, _, version) in vendors.items():
        state = pins[name.lower()]
        revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=stage / "Vendor" / name, text=True).strip()
        assert state.get("version") == version and state["revision"] == revision, (name, state, version, revision)
    print("Verified the complete dependency graph and patched vendor revisions")


if __name__ == "__main__":
    main()
