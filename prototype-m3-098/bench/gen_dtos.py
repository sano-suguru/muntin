import sys, os
out = sys.argv[1]; N = int(sys.argv[2])
os.makedirs(out, exist_ok=True)
KINDS = ["Int", "String", "Float64", "Bool", "List[Int]", "Optional[String]"]
def fields(n, prefix="f"):
    return [(f"{prefix}_{i}_x", KINDS[i % len(KINDS)]) for i in range(n)]
def struct(name, fs, traits="JsonFields", members=None, extra=()):
    s = f"@fieldwise_init\nstruct {name}({traits}):\n"
    for f, t in fs: s += f"    var {f}: {t}\n"
    for f, t in extra: s += f"    var {f}: {t}\n"
    if members is not None:
        s += "\n    @staticmethod\n    def json_members() -> List[JsonMember]:\n        return [\n"
        for m in members: s += f"            {m},\n"
        s += "        ]\n"
    return s + "\n\n"
def route(i, name):
    return f"def h{i}(var body: Json[{name}]) -> Json[{name}]:\n    return body^\n\n\n"
HDR = "from muntin import App, Json, JsonFields\n\n\n"
HDR_M = "from muntin import App, Json, JsonCamelCase, JsonFields, JsonMember, JsonMembers\n\n\n"
def main_(n):
    s = "def main() raises:\n    var app = App()\n"
    for i in range(n): s += f'    app.post["/r{i}"](h{i})\n'
    return s
# plain100
src = HDR + struct("D", fields(N)) + route(0, "D") + main_(1)
open(f"{out}/plain{N}.mojo", "w").write(src)
# nested: 5 levels of 20 fields, each holding the next
src = HDR
for lvl in range(4, -1, -1):
    extra = [("child", f"N{lvl+1}")] if lvl < 4 else []
    src += struct(f"N{lvl}", fields(20, f"l{lvl}"), extra=extra)
src += route(0, "N0") + main_(1)
open(f"{out}/nested5x20.mojo", "w").write(src)
# routes20: 20 structs x 20 fields
src = HDR
for r in range(20): src += struct(f"R{r}", fields(20, f"r{r}"))
for r in range(20): src += route(r, f"R{r}")
src += main_(20)
open(f"{out}/routes20x20.mojo", "w").write(src)
# opted100: camelCase + 10 renames + 10 defaults (prototype only)
fs = fields(N)
mem = []
for i in range(0, N, 10): mem.append(f'JsonMember("{fs[i][0]}", name="m{i}")')
dflt = {"Int": '"7"', "String": "'\"s\"'", "Float64": '"1.5"', "Bool": '"true"', "List[Int]": '"[1,2]"', "Optional[String]": "'\"o\"'"}
for i in range(5, N, 10): mem.append(f'JsonMember("{fs[i][0]}", default={dflt[fs[i][1]]})')
src = HDR_M + struct("D", fs, "JsonCamelCase, JsonMembers", mem) + route(0, "D") + main_(1)
open(f"{out}/opted{N}.mojo", "w").write(src)
