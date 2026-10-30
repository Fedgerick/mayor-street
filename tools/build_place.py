#!/usr/bin/env python3
"""Pack src/ into a Roblox place file (.rbxlx) that opens in Roblox Studio.

Follows the same layout and naming rules as default.project.json under Rojo:
  *.server.luau -> Script, *.client.luau -> LocalScript, other *.luau -> ModuleScript.
Usage: python3 tools/build_place.py [out.rbxlx]
"""
import itertools
import os
import sys
from xml.sax.saxutils import escape

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# (service, path inside the service, source folder)
LAYOUT = [
    ("ReplicatedStorage", ["Shared"], "src/shared"),
    ("ServerScriptService", [], "src/server"),
    ("StarterPlayer", ["StarterPlayerScripts"], "src/client"),
]
CONTAINERS = {"StarterPlayerScripts": "StarterPlayerScripts"}

_ref = itertools.count(1)


def ref():
    return "RBX%08X" % next(_ref)


def script_item(path):
    name = os.path.basename(path)[: -len(".luau")]
    cls = "ModuleScript"
    if name.endswith(".server"):
        cls, name = "Script", name[: -len(".server")]
    elif name.endswith(".client"):
        cls, name = "LocalScript", name[: -len(".client")]
    with open(path, encoding="utf-8") as f:
        src = f.read()
    if "]]>" in src:
        raise SystemExit(f"{path}: contains ]]>, which can't go in CDATA")
    return (
        f'<Item class="{cls}" referent="{ref()}"><Properties>'
        f'<string name="Name">{escape(name)}</string>'
        f'<ProtectedString name="Source"><![CDATA[{src}]]></ProtectedString>'
        f"</Properties></Item>"
    )


def folder_items(folder):
    out = []
    for entry in sorted(os.listdir(folder)):
        p = os.path.join(folder, entry)
        if os.path.isdir(p):
            out.append(
                f'<Item class="Folder" referent="{ref()}"><Properties>'
                f'<string name="Name">{escape(entry)}</string></Properties>'
                + "".join(folder_items(p))
                + "</Item>"
            )
        elif entry.endswith(".luau"):
            out.append(script_item(p))
    return out


def wrap(cls, name, inner):
    return (
        f'<Item class="{cls}" referent="{ref()}"><Properties>'
        f'<string name="Name">{escape(name)}</string></Properties>{inner}</Item>'
    )


def build():
    services = {}
    for service, chain, src in LAYOUT:
        inner = "".join(folder_items(os.path.join(ROOT, src)))
        for name in reversed(chain):
            inner = wrap(CONTAINERS.get(name, "Folder"), name, inner)
        services.setdefault(service, []).append(inner)
    body = "".join(wrap(s, s, "".join(parts)) for s, parts in services.items())
    return (
        '<roblox xmlns:xmime="http://www.w3.org/2005/05/xmlmime" '
        'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
        'xsi:noNamespaceSchemaLocation="http://www.roblox.com/roblox.xsd" version="4">'
        + body
        + "</roblox>"
    )


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "build", "MayorStreetRoblox.rbxlx")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        f.write(build())
    print("wrote", out)
