#!/usr/bin/env bash
# Developer-experience comparison: one small users API written with Muntin
# (bench/compare/users_muntin.mojo) and against Flare alone
# (bench/compare/users_flare.mojo). Not run by CI.
#
#   ./scripts/compare_dx.sh
#
# In the `flare` environment, it
# 1. counts each program's code lines (not blank, not a comment, not the
#    module docstring), its import lines and the names it imports;
# 2. builds both, serves each on a loopback port, sends the requests in
#    bench/compare/requests.tsv with curl and fails if either program answers
#    one otherwise; then prints both answers to bench/compare/defaults.tsv,
#    which the specification leaves open;
# 3. plants each mistake in bench/compare/mistakes.txt in a copy of the
#    program it names and reports whether the copy builds: the compiler's
#    first error if not, otherwise what the copy answers to the mistake's
#    request.
# Builds go under build/compare_dx. Needs curl and python3.
set -euo pipefail
cd "$(dirname "$0")/.."

FLARE=(pixi run --frozen -e flare mojo)
"${FLARE[@]}" --version
pixi list --frozen -e flare '^flare$' | tail -n 1

dir=bench/compare
out=build/compare_dx
rm -rf "$out"
mkdir -p "$out"
pids=()
cleanup() {
    for pid in "${pids[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
}
trap cleanup EXIT

step() { printf '\n== %s\n' "$*"; }

build() { # SRC OUT: builds SRC to OUT, the log in OUT.log
    "${FLARE[@]}" build -I src -I adapters/flare "$1" -o "$2" >"$2.log" 2>&1
}

free_port() {
    python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}

start() { # BINARY VAR: serves BINARY on a free port, sets VAR to it once it answers
    local p
    p="$(free_port)"
    "$1" "$p" >"$1.serve.log" 2>&1 &
    pids+=($!)
    for _ in $(seq 1 100); do
        if curl -s --noproxy '*' -o /dev/null "http://127.0.0.1:$p/"; then
            printf -v "$2" "%s" "$p"
            return
        fi
        sleep 0.1
    done
    cat "$1.serve.log" >&2
    echo "error: $1 did not answer on port $p" >&2
    exit 1
}

ask() { # PORT METHOD TARGET BODY CONTENT_TYPE: prints status, Content-Type, Allow and body, tab-separated
    local args=(-s --noproxy '*' -X "$2" -D "$out/headers" -o "$out/body")
    if [[ $2 == HEAD ]]; then
        args=(-s --noproxy '*' -I -D "$out/headers" -o /dev/null)
        : >"$out/body"
    fi
    if [[ $4 != - ]]; then
        args+=(--data-binary "$4")
        if [[ $5 == - ]]; then
            args+=(-H 'Content-Type:')
        else
            args+=(-H "Content-Type: $5")
        fi
    fi
    local status
    status="$(curl "${args[@]}" -w '%{http_code}' "http://127.0.0.1:$1$3")"
    local ctype allow
    ctype="$(sed -n 's/^[Cc]ontent-[Tt]ype: *\(.*\)\r$/\1/p' "$out/headers")"
    allow="$(sed -n 's/^[Aa]llow: *\(.*\)\r$/\1/p' "$out/headers")"
    printf '%s\t%s\t%s\t%s\n' "$status" "${ctype:--}" "${allow:--}" "$(cat "$out/body")"
}

diagnostic() { # BASE: summarizes the compiler output BASE.log for BASE.mojo
    python3 -I - "$1" <<'PY'
import re
import sys

base = sys.argv[1]
log = open(base + ".log").read().splitlines()
src = open(base + ".mojo").read().split("\n")
# The rule a registration check states, else the first error.
msg = next((l.split("note: ", 1)[1] for l in log if "note: constraint failed:" in l), None)
if msg is None:
    msg = next(l.split("error: ", 1)[1] for l in log if "error: " in l)
# The lines of the program the diagnostic names, in order.
own = []
for l in log:
    m = re.match(r"\S*" + re.escape(base.split("/")[-1]) + r"\.mojo:(\d+):\d+: ", l)
    if m and int(m.group(1)) not in own:
        own.append(int(m.group(1)))
where = "; ".join(f"line {n}: {src[n - 1].strip()}" for n in own)
print(f"{msg} [{len(log)} lines of compiler output; names {where}]")
PY
}

step "code size (lines that are not blank, a comment or the module docstring)"
python3 -I - "$dir/users_muntin.mojo" "$dir/users_flare.mojo" <<'PY'
import re
import sys

print("program\tcode lines\timport lines\timported names")
for path in sys.argv[1:]:
    text = open(path).read()
    if text.startswith('"""'):
        text = text[text.index('"""', 3) + 3 :]
    code = [l for l in text.splitlines() if l.strip() and not l.strip().startswith("#")]
    imports, names, depth = 0, 0, 0
    for line in code:
        s = line.strip()
        if depth or s.startswith(("from ", "import ")):
            imports += 1
            part = s.split(" import ", 1)[1] if " import " in s else s
            names += len([n for n in re.split(r"[(),\s]+", part) if n])
            depth += s.count("(") - s.count(")")
    print(f"{path}\t{len(code)}\t{imports}\t{names}")
PY

step "build both programs"
build "$dir/users_muntin.mojo" "$out/users_muntin" &
muntin_build=$!
build "$dir/users_flare.mojo" "$out/users_flare" &
flare_build=$!
for pair in "$muntin_build users_muntin" "$flare_build users_flare"; do
    read -r pid name <<<"$pair"
    if ! wait "$pid"; then
        cat "$out/$name.log"
        echo "error: $dir/$name.mojo did not build" >&2
        exit 1
    fi
    echo "ok: $out/$name"
done
start "$out/users_muntin" muntin_port
start "$out/users_flare" flare_port

step "the specification (bench/compare/requests.tsv): status and body, both programs"
failed=0
while IFS=$'\t' read -r method target body status expected; do
    [[ -z $method || $method == \#* ]] && continue
    for prog in muntin flare; do
        port_var="${prog}_port"
        IFS=$'\t' read -r got_status _ _ got_body < <(ask "${!port_var}" "$method" "$target" "$body" application/json)
        if [[ $got_status == "$status" && $got_body == "$expected" ]]; then
            printf 'ok\t%s\t%s %s\t%s\n' "$prog" "$method" "$target" "$status"
        else
            printf 'FAIL\t%s\t%s %s\t%s %s, expected %s %s\n' "$prog" "$method" "$target" \
                "$got_status" "$got_body" "$status" "$expected"
            failed=1
        fi
    done
done <"$dir/requests.tsv"
if ((failed)); then
    echo "error: a program does not answer as bench/compare/requests.tsv specifies" >&2
    exit 1
fi

step "left open by the specification (bench/compare/defaults.tsv): status, Content-Type, Allow, body"
while IFS=$'\t' read -r method target body ctype; do
    [[ -z $method || $method == \#* ]] && continue
    sent="$method $target"
    [[ $body != - ]] && sent+=" $body (Content-Type: ${ctype/#-/none})"
    echo "$sent"
    printf '  muntin\t%s\n' "$(ask "$muntin_port" "$method" "$target" "$body" "$ctype")"
    printf '  flare\t%s\n' "$(ask "$flare_port" "$method" "$target" "$body" "$ctype")"
done <"$dir/defaults.tsv"
cleanup
pids=()

step "mistakes (bench/compare/mistakes.txt), built in parallel"
python3 -I - "$dir/mistakes.txt" "$dir" "$out" <<'PY'
import sys

mistakes_file, src_dir, out_dir = sys.argv[1:]
blocks, cur = [], None
for raw in open(mistakes_file).read().splitlines():
    if raw.startswith("== "):
        name, prog, method, target, *body = raw[3:].split(" ", 4)
        cur = {"name": name, "prog": prog, "probe": (method, target, body[0] if body else "-"), "edits": []}
        blocks.append(cur)
    elif raw.startswith("- "):
        cur["edits"].append([raw[2:], None])
    elif raw.startswith("+ "):
        cur["edits"][-1][1] = raw[2:]
with open(f"{out_dir}/mistakes.tsv", "w") as listing:
    for b in blocks:
        lines = open(f"{src_dir}/users_{b['prog']}.mojo").read().split("\n")
        # Every `-` line is matched against the program as written, so two
        # edits can swap two lines.
        replace = {}
        for old, new in b["edits"]:
            hits = [i for i, l in enumerate(lines) if l.strip() == old]
            if not hits or new is None:
                sys.exit(f"error: {b['name']} ({b['prog']}): no line '{old}', or no replacement")
            for i in hits:
                indent = lines[i][: len(lines[i]) - len(lines[i].lstrip())]
                replace[i] = indent + new
        for i, line in replace.items():
            lines[i] = line
        path = f"{out_dir}/{b['name']}_{b['prog']}.mojo"
        open(path, "w").write("\n".join(lines))
        listing.write("\t".join([b["name"], b["prog"], *b["probe"]]) + "\n")
PY
names=()
while IFS=$'\t' read -r name prog _; do
    names+=("${name}_$prog")
    build "$out/${name}_$prog.mojo" "$out/${name}_$prog" &
    pids+=($!)
done <"$out/mistakes.tsv"
statuses=()
for pid in "${pids[@]}"; do
    if wait "$pid"; then statuses+=(0); else statuses+=(1); fi
done
pids=()
i=0
while IFS=$'\t' read -r name prog method target body; do
    printf '%s\t%s\t' "$name" "$prog"
    if [[ $(grep -c " $name " "$dir/mistakes.txt") -lt 2 ]]; then
        printf '(no counterpart in the other program)\t'
    fi
    if ((statuses[i])); then
        printf 'does not build: '
        diagnostic "$out/${name}_$prog"
    else
        start "$out/${name}_$prog" port
        IFS=$'\t' read -r st _ _ got < <(ask "$port" "$method" "$target" "$body" application/json)
        printf 'builds; %s %s -> %s %s\n' "$method" "$target" "$st" "$got"
        cleanup
        pids=()
    fi
    i=$((i + 1))
done <"$out/mistakes.tsv"
