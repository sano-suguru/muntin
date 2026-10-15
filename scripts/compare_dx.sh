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
#    request. It builds at most COMPARE_JOBS copies at once (default 4), and
#    fails if a copy does not build without a compiler error (such as a
#    compiler killed for lack of memory), which is not a rejected mistake.
# Builds go under build/compare_dx. Every request has a 10 s limit, and a
# transfer curl reports as failed (exit status not 0, such as a body shorter
# than its Content-Length) fails a specified request whatever was received.
# Needs bash 4.3 or later (`wait -n`; macOS ships 3.2), curl, cmp and python3.
set -euo pipefail
cd "$(dirname "$0")/.."

if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3))); then
    echo "error: needs bash 4.3 or later, found $BASH_VERSION" >&2
    exit 1
fi

FLARE=(pixi run --frozen -e flare mojo)
"${FLARE[@]}" --version
pixi list --frozen -e flare '^flare$' | tail -n 1

dir=bench/compare
out=build/compare_dx
rm -rf "$out"
mkdir -p "$out"
jobs_max="${COMPARE_JOBS:-4}"
if ! [[ $jobs_max =~ ^[1-9][0-9]*$ ]]; then
    echo "error: COMPARE_JOBS must be a positive integer: $jobs_max" >&2
    exit 1
fi
CURL=(curl -s --noproxy '*' --connect-timeout 2 --max-time 10)
pids=()
cleanup() {
    for pid in "${pids[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
}
trap cleanup EXIT

step() { printf '\n== %s\n' "$*"; }

build() { # SRC OUT: builds SRC to OUT, the log in OUT.log, the exit status in OUT.status
    local status=0
    "${FLARE[@]}" build -I src -I adapters/flare "$1" -o "$2" >"$2.log" 2>&1 || status=$?
    echo "$status" >"$2.status"
    return "$status"
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
        if "${CURL[@]}" -o /dev/null "http://127.0.0.1:$p/"; then
            printf -v "$2" "%s" "$p"
            return
        fi
        sleep 0.1
    done
    cat "$1.serve.log" >&2
    echo "error: $1 did not answer on port $p" >&2
    exit 1
}

ask() { # PORT METHOD TARGET BODY CONTENT_TYPE: prints status, Content-Type, Allow and body,
    # tab-separated; the body exactly as received is left in $out/body. Returns
    # curl's exit status, printing nothing, when curl reports the transfer failed.
    local args=(-X "$2" -D "$out/headers" -o "$out/body")
    if [[ $2 == HEAD ]]; then
        args=(-I -D "$out/headers" -o /dev/null)
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
    : >"$out/headers"
    local status code=0
    status="$("${CURL[@]}" "${args[@]}" -w '%{http_code}' "http://127.0.0.1:$1$3")" || code=$?
    if ((code != 0)); then
        return "$code"
    fi
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
# The rule a registration check states, else the first error at a source
# location (path:line:column: error: ...).
msg = next((l.split("note: ", 1)[1] for l in log if "note: constraint failed:" in l), None)
if msg is None:
    msg = next((l.split("error: ", 1)[1] for l in log if re.match(r"\S+:\d+:\d+: error: ", l)), None)
if msg is None:
    print(f"no compiler error in {base}.log: the build failed for another reason")
    sys.exit(1)
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
        code=0
        response="$(ask "${!port_var}" "$method" "$target" "$body" application/json)" || code=$?
        if ((code != 0)); then
            printf 'FAIL\t%s\t%s %s\tthe transfer failed (curl exit %s)\n' "$prog" "$method" "$target" "$code"
            failed=1
            continue
        fi
        IFS=$'\t' read -r got_status _ _ got_body <<<"$response"
        # The body is compared byte for byte, a trailing newline included.
        printf '%s' "$expected" >"$out/expected"
        if [[ $got_status == "$status" ]] && cmp -s "$out/body" "$out/expected"; then
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
    for prog in muntin flare; do
        port_var="${prog}_port"
        response="$(ask "${!port_var}" "$method" "$target" "$body" "$ctype")" ||
            response="the transfer failed (curl exit $?)"
        printf '  %s\t%s\n' "$prog" "$response"
    done
done <"$dir/defaults.tsv"
cleanup
pids=()

step "mistakes (bench/compare/mistakes.txt), built $jobs_max at a time"
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
            if len(hits) != 1 or new is None:
                sys.exit(f"error: {b['name']} ({b['prog']}): expected exactly one line '{old}' "
                         f"and a replacement; found {len(hits)} line(s)")
            i = hits[0]
            indent = lines[i][: len(lines[i]) - len(lines[i].lstrip())]
            replace[i] = indent + new
        for i, line in replace.items():
            lines[i] = line
        path = f"{out_dir}/{b['name']}_{b['prog']}.mojo"
        open(path, "w").write("\n".join(lines))
        listing.write("\t".join([b["name"], b["prog"], *b["probe"]]) + "\n")
PY
while IFS=$'\t' read -r name prog _; do
    while (($(jobs -rp | wc -l) >= jobs_max)); do
        wait -n || true
    done
    build "$out/${name}_$prog.mojo" "$out/${name}_$prog" &
done <"$out/mistakes.tsv"
wait || true
unexplained=0
while IFS=$'\t' read -r name prog method target body; do
    printf '%s\t%s\t' "$name" "$prog"
    if [[ $(grep -c " $name " "$dir/mistakes.txt") -lt 2 ]]; then
        printf '(no counterpart in the other program)\t'
    fi
    if [[ $(cat "$out/${name}_$prog.status") != 0 ]]; then
        printf 'does not build: '
        diagnostic "$out/${name}_$prog" || unexplained=1
    else
        start "$out/${name}_$prog" port
        if response="$(ask "$port" "$method" "$target" "$body" application/json)"; then
            IFS=$'\t' read -r st _ _ got <<<"$response"
            printf 'builds; %s %s -> %s %s\n' "$method" "$target" "$st" "$got"
        else
            printf 'builds; %s %s -> the transfer failed (curl exit %s)\n' "$method" "$target" "$?"
        fi
        cleanup
        pids=()
    fi
done <"$out/mistakes.tsv"
if ((unexplained)); then
    echo "error: a mistaken copy failed to build without a compiler error; see its log under $out" >&2
    exit 1
fi
