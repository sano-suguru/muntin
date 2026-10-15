#!/usr/bin/env bash
# Flare checks: builds and runs compat/flare, the Flare adapter's contract
# tests, its `Server` tests and its real localhost round trips
# (adapters/flare), and builds examples/hello_server.mojo, against the Flare
# release pinned in pixi.toml's `flare` environment, and checks that the
# default environment (which builds src/muntin) cannot see Flare. Exits nonzero
# on any failure.
set -euo pipefail
cd "$(dirname "$0")/.."

EXPECTED_MOJO="Mojo 1.1.0"
FLARE=(pixi run --frozen -e flare mojo)
DEFAULT=(pixi run --frozen mojo)
fixture=compat/flare/flare_smoke.mojo
adapter=adapters/flare
adapter_tests=$adapter/test_muntin_flare.mojo
serve_probe=$adapter/serve_probe.mojo
roundtrip=$adapter/test_localhost_roundtrip.mojo
server_tests=$adapter/test_server.mojo
# M3-051: Server over TLS; reads the PEM files written under build/tls below.
tls_tests=$adapter/test_tls.mojo
# M3-045: the program test_server.mojo execs for its stop tests.
stop_driver=$adapter/stop_driver.mojo
# M3-051: a TLS Server on a chosen port, asked by openssl s_client below.
tls_probe=$adapter/tls_probe.mojo
example=examples/hello_server.mojo
tls_example=examples/hello_https.mojo
# M3-032's must-not-build fixtures for Server (docs/history/architecture-decisions.md
# "Serving entrypoint decision (M3-032)") and M3-044's ("Server receive body
# limit decision (M3-044)") and M3-049's ("Multi-worker serving decision
# (M3-049)"), built with -I src -I $adapter.
serve_fixtures=(
    compat/flare/serve/workers_need_copyable.mojo
    compat/flare/serve/server_handler_not_copyable.mojo
    compat/flare/serve/server_positional_init.mojo
    compat/flare/serve/server_keyword_init.mojo
    compat/flare/serve/server_bind_positional_limit.mojo
    compat/flare/serve/serve_workers_capturing_make.mojo
    compat/flare/serve/serve_workers_runtime_closure.mojo
)

step() { printf '\n== %s\n' "$*"; }

step "toolchain (flare environment)"
version="$("${FLARE[@]}" --version)"
echo "$version"
if [[ "$version" != "$EXPECTED_MOJO "* ]]; then
    echo "error: expected $EXPECTED_MOJO, found: $version" >&2
    exit 1
fi
FLARE_COMMIT="8c6e1400a6214fc1c763f8ae5e7adfcc0156661e" # tag v0.12.0
listing="$(pixi list --frozen -e flare '^flare$')"
echo "$listing"
if ! grep -q "tag=v0.12.0#$FLARE_COMMIT" <<<"$listing"; then
    echo "error: flare env is not at v0.12.0 ($FLARE_COMMIT)" >&2
    exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

step "format adapter"
cp -R "$adapter" "$tmp/adapter"
"${FLARE[@]}" format --quiet "$tmp/adapter"
if ! diff -ru "$adapter" "$tmp/adapter"; then
    echo "error: $adapter is not formatted; run: pixi run -e flare mojo format $adapter" >&2
    exit 1
fi
for ex in "$example" "$tls_example"; do
    cp "$ex" "$tmp/example.mojo"
    "${FLARE[@]}" format --quiet "$tmp/example.mojo"
    if ! diff -u "$ex" "$tmp/example.mojo"; then
        echo "error: $ex is not formatted; run: pixi run -e flare mojo format $ex" >&2
        exit 1
    fi
done
echo "ok"

# Every Flare binary is built here, one per CPU at a time; the steps below
# run them in order.
mkdir -p build
pids=()
outs=()
known=()
# Every build in this step is --Werror except those that reach Flare's
# HttpClient: Flare v0.12.0 (8c6e1400) warns in its own source there, on
# exactly this line. Those builds fail on any other warning line, and also when
# this line is gone, which means a Flare release has fixed it: build them with
# --Werror again.
flare_src="$(pwd -P)/.pixi/envs/flare/lib/mojo/" # mojo prints resolved paths
KNOWN_WARNING="${flare_src}flare/http/_client/parse.mojo:867:18: warning: assignment to 'http11' was never used; assign to '_' instead?"
# More builds than CPUs only compete for the same cores and memory.
jobs_max="$(getconf _NPROCESSORS_ONLN)"
throttle() {
    while (($(jobs -rp | wc -l) >= jobs_max)); do
        sleep 0.2
    done
}
build_bg() { # OUT ARGS...: mojo build --Werror ARGS -o build/OUT, in the background
    local out="$1"
    shift
    throttle
    "${FLARE[@]}" build --Werror "$@" -o "build/$out" >"$tmp/build_$out.log" 2>&1 &
    pids+=($!)
    outs+=("$out")
    known+=(0)
}
build_bg_known() { # OUT ARGS...: as build_bg, without --Werror; checked for KNOWN_WARNING only
    local out="$1"
    shift
    throttle
    "${FLARE[@]}" build "$@" -o "build/$out" >"$tmp/build_$out.log" 2>&1 &
    pids+=($!)
    outs+=("$out")
    known+=(1)
}
step "build fixture, adapter tests and probes (in parallel, one per CPU)"
build_bg flare_smoke "$fixture"
build_bg test_muntin_flare -I src -I "$adapter" "$adapter_tests"
build_bg serve_probe -I src -I "$adapter" "$serve_probe"
build_bg_known test_localhost_roundtrip -I src -I "$adapter" "$roundtrip"
build_bg test_server -I src -I "$adapter" "$server_tests"
build_bg stop_driver -I src -I "$adapter" "$stop_driver"
build_bg tls_probe -I src -I "$adapter" "$tls_probe"
build_bg test_tls -I src -I "$adapter" "$tls_tests"
build_bg hello_server -I src -I "$adapter" "$example"
build_bg hello_https -I src -I "$adapter" "$tls_example"
build_bg flare_header_probe -I src -I "$adapter" compat/flare/headers/flare_header_probe.mojo
build_bg inbound_rebuild -I src -I tests -I "$adapter" compat/flare/headers/inbound_rebuild.mojo
build_bg write_to_pieces -I src -I "$adapter" -I compat/flare/headers compat/flare/headers/write_to_pieces.mojo
build_bg_known json_loopback_probe -I src -I tests -I "$adapter" compat/flare/json/json_loopback_probe.mojo
build_bg head_probe -I src -I "$adapter" compat/flare/head/head_probe.mojo
build_bg body_probe compat/flare/body/body_probe.mojo
build_bg stream_probe compat/flare/stream/stream_probe.mojo
built=0
for i in "${!pids[@]}"; do
    log="$tmp/build_${outs[i]}.log"
    problem=""
    if ! wait "${pids[i]}"; then
        problem="build of build/${outs[i]} failed"
    elif ((known[i])); then
        others="$(grep -F 'warning:' "$log" | grep -vxF "$KNOWN_WARNING" || true)"
        if [[ -n "$others" ]]; then
            problem="build of build/${outs[i]} has a warning other than Flare's known one"
        elif ! grep -qxF "$KNOWN_WARNING" "$log"; then
            problem="Flare's known warning is gone: build build/${outs[i]} with --Werror and remove the exception"
        fi
    fi
    if [[ -z "$problem" ]]; then
        echo "ok: build/${outs[i]}"
    else
        cat "$log"
        echo "error: $problem" >&2
        built=1
    fi
done
if ((built != 0)); then
    exit 1
fi

step "run fixture"
out="$(./build/flare_smoke)"
echo "$out"
if [[ "$out" != "200 hello" ]]; then
    echo "error: expected '200 hello' from $fixture" >&2
    exit 1
fi

step "run adapter tests"
if ! out="$(./build/test_muntin_flare 2>&1)"; then
    printf '%s\n' "$out"
    echo "error: adapter contract tests failed" >&2
    exit 1
fi
printf '%s\n' "$out"
if ! grep -qE 'Summary .* [1-9][0-9]* tests run' <<<"$out"; then
    echo "error: $adapter_tests ran no tests" >&2
    exit 1
fi

step "serve probe (compile-only: HttpServer.serve accepts MuntinHandler)"
./build/serve_probe

step "run localhost round trip (GET /hello, typed GET routes, body-only and route-value-then-body POSTs over loopback: Flare -> Server -> App.handle)"
# Output goes to a file, not a pipe: a leftover child holding the pipe would
# make the shell wait for it and hide it from the pgrep check below.
status=0
# NO_PROXY keeps Flare's client from routing loopback through an HTTP_PROXY.
NO_PROXY=127.0.0.1 ./build/test_localhost_roundtrip >"$tmp/roundtrip.log" 2>&1 || status=$?
cat "$tmp/roundtrip.log"
# The test forks a server child; it must be reaped, not left serving.
leftover='^\./build/test_localhost_roundtrip$'
if pgrep -f "$leftover"; then
    pkill -KILL -f "$leftover" || true
    echo "error: $roundtrip left a server process behind" >&2
    exit 1
fi
if ((status != 0)); then
    echo "error: localhost round trip failed" >&2
    exit 1
fi
if ! grep -qE 'Summary .* [1-9][0-9]* tests run' "$tmp/roundtrip.log"; then
    echo "error: $roundtrip ran no tests" >&2
    exit 1
fi
echo "ok: no server process left behind"

# M3-033: Server.bind, port and serve (the example is built above, not run:
# it binds the fixed port 8080).
step "run Server tests (bind, port, the receive body limit, serve a borrowed App, graceful stop on SIGTERM and SIGINT)"
server_status=0
NO_PROXY=127.0.0.1 ./build/test_server >"$tmp/server.log" 2>&1 || server_status=$?
cat "$tmp/server.log"
leftover_server='^\./build/(test_server|stop_driver)( |$)'
if pgrep -f "$leftover_server"; then
    pkill -KILL -f "$leftover_server" || true
    echo "error: $server_tests left a server process behind" >&2
    exit 1
fi
if ((server_status != 0)); then
    echo "error: Server tests failed" >&2
    exit 1
fi
if ! grep -qE 'Summary .* [1-9][0-9]* tests run' "$tmp/server.log"; then
    echo "error: $server_tests ran no tests" >&2
    exit 1
fi
echo "ok: no server process left behind"

# M3-051: the PEM files test_tls reads, made fresh with the flare
# environment's OpenSSL: a self-signed certificate for 127.0.0.1 and its key,
# the key in the older EC form, plain and encrypted, a key that does not
# belong to it, that key encrypted, and the certificate
# with a damaged byte in its PEM block; a root CA, an intermediate it signs
# and a certificate for 127.0.0.1 the intermediate signs, with that
# certificate alone and followed by the intermediate; key files whose text
# names an encrypted key outside a PEM block, or holds an encrypted key
# before a plain one; a symbolic link to the certificate, a FIFO and a
# file one byte over Server's 1 MiB limit.
step "run Server TLS tests (HTTPS over HTTP/1.1 and HTTP/2, start-up errors, the three settings)"
OPENSSL=(pixi run --frozen -e flare openssl)
rm -rf build/tls
mkdir -p build/tls
"${OPENSSL[@]}" req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -keyout build/tls/key.pem -out build/tls/cert.pem -days 1 \
    -subj /CN=127.0.0.1 -addext subjectAltName=IP:127.0.0.1 2>"$tmp/openssl.log" ||
    { cat "$tmp/openssl.log"; exit 1; }
"${OPENSSL[@]}" genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 \
    -out build/tls/other_key.pem
"${OPENSSL[@]}" pkey -in build/tls/key.pem -aes256 -passout pass:muntin \
    -out build/tls/encrypted_key.pem
"${OPENSSL[@]}" pkey -in build/tls/key.pem -traditional \
    -out build/tls/traditional_key.pem
"${OPENSSL[@]}" pkey -in build/tls/key.pem -traditional -aes256 \
    -passout pass:muntin -out build/tls/traditional_encrypted_key.pem
sed '2s/^./!/' build/tls/cert.pem >build/tls/damaged_cert.pem
tls_ca() { # name, subject, signer (empty: self-signed), extensions
    local d=build/tls
    "${OPENSSL[@]}" genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 \
        -out "$d/$1_key.pem"
    printf '%s\n' "$4" >"$d/$1.ext"
    "${OPENSSL[@]}" req -new -key "$d/$1_key.pem" -subj "$2" -out "$d/$1.csr"
    if [[ -z $3 ]]; then
        "${OPENSSL[@]}" x509 -req -in "$d/$1.csr" -key "$d/$1_key.pem" \
            -days 1 -extfile "$d/$1.ext" -out "$d/$1.pem" 2>"$tmp/openssl.log"
    else
        "${OPENSSL[@]}" x509 -req -in "$d/$1.csr" -CA "$d/$3.pem" \
            -CAkey "$d/$3_key.pem" -CAcreateserial -days 1 \
            -extfile "$d/$1.ext" -out "$d/$1.pem" 2>"$tmp/openssl.log"
    fi || { cat "$tmp/openssl.log"; exit 1; }
}
ca_ext=$'basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign'
tls_ca root "/CN=Muntin test root" "" "$ca_ext"
tls_ca intermediate "/CN=Muntin test intermediate" root "$ca_ext"
tls_ca leaf /CN=127.0.0.1 intermediate \
    $'basicConstraints=critical,CA:FALSE\nsubjectAltName=IP:127.0.0.1'
cat build/tls/leaf.pem build/tls/intermediate.pem >build/tls/chain.pem
{
    echo "Not -----BEGIN ENCRYPTED PRIVATE KEY----- nor Proc-Type: 4,ENCRYPTED"
    cat build/tls/key.pem build/tls/encrypted_key.pem
} >build/tls/commented_key.pem
cat build/tls/encrypted_key.pem build/tls/key.pem >build/tls/encrypted_first_key.pem
ln -s cert.pem build/tls/cert_link.pem
mkfifo build/tls/fifo.pem
dd if=/dev/zero of=build/tls/big.pem bs=1 count=0 seek=1048577 2>/dev/null
# pad_to SOURCE BYTES TARGET: SOURCE, then comment lines up to BYTES in all.
pad_to() {
    local need=$(($2 - $(wc -c <"$1")))
    {
        cat "$1"
        awk -v n="$need" 'BEGIN {
            line = "# padding after the PEM block"
            while (n > length(line) + 1) { print line; n -= length(line) + 1 }
            s = ""; while (n > 1) { s = s "#"; n-- }; print s
        }'
    } >"$3"
    [[ $(wc -c <"$3") -eq $2 ]] || { echo "pad_to: $3 is not $2 bytes"; exit 1; }
}
pad_to build/tls/cert.pem 16384 build/tls/cert_16384.pem
pad_to build/tls/key.pem 16385 build/tls/key_16385.pem
pad_to build/tls/cert.pem 1048576 build/tls/cert_1048576.pem
pad_to build/tls/key.pem 1048576 build/tls/key_1048576.pem
pad_to build/tls/cert.pem 1048577 build/tls/cert_1048577.pem
tls_status=0
NO_PROXY=127.0.0.1 ./build/test_tls >"$tmp/tls.log" 2>&1 || tls_status=$?
cat "$tmp/tls.log"
leftover_tls='^\./build/test_tls$'
if pgrep -f "$leftover_tls"; then
    pkill -KILL -f "$leftover_tls" || true
    echo "error: $tls_tests left a server process behind" >&2
    exit 1
fi
if ((tls_status != 0)); then
    echo "error: Server TLS tests failed" >&2
    exit 1
fi
if ! grep -qE 'Summary .* [1-9][0-9]* tests run' "$tmp/tls.log"; then
    echo "error: $tls_tests ran no tests" >&2
    exit 1
fi
echo "ok: no server process left behind"

# M3-051: the TLS versions and ciphers a TLS Server accepts, asked of
# $tls_probe (a port the system chooses, printed once bound) by the flare
# environment's `openssl s_client`, which is told to offer even what its own
# defaults refuse (SECLEVEL=0), so a refusal is the server's alert.
step "TLS versions and ciphers of a TLS Server (openssl s_client against $tls_probe)"
./build/tls_probe >"$tmp/tls_probe.log" 2>&1 &
https_pid=$!
https_port=
for _ in $(seq 1 100); do
    https_port=$(sed -n 's/^listening on 127\.0\.0\.1:\([0-9]*\)$/\1/p' "$tmp/tls_probe.log")
    [[ -n $https_port ]] && break
    sleep 0.1
done
if [[ -z $https_port ]]; then
    kill "$https_pid" 2>/dev/null || true
    cat "$tmp/tls_probe.log"
    echo "error: $tls_probe did not report its port" >&2
    exit 1
fi
s_client() { # name, s_client arguments...
    local name=$1
    shift
    "${OPENSSL[@]}" s_client -connect "127.0.0.1:$https_port" -CAfile build/tls/cert.pem \
        "$@" </dev/null >"$tmp/s_client_$name.log" 2>&1
}
tls_probe_status=0
expect_s_client() { # name, ok|alert text, s_client arguments...
    local name=$1 want=$2
    shift 2
    if s_client "$name" "$@"; then
        if [[ $want == ok ]] && grep -q 'Verify return code: 0 (ok)' "$tmp/s_client_$name.log"; then
            echo "ok: $name accepted and verified"
            return
        fi
    elif [[ $want != ok ]] && grep -q "$want" "$tmp/s_client_$name.log"; then
        echo "ok: $name refused by the server ($want)"
        return
    fi
    cat "$tmp/s_client_$name.log"
    echo "error: $name: expected $want" >&2
    tls_probe_status=1
}
expect_s_client "TLS 1.0" "alert protocol version" -tls1 -cipher 'DEFAULT@SECLEVEL=0'
expect_s_client "TLS 1.1" "alert protocol version" -tls1_1 -cipher 'DEFAULT@SECLEVEL=0'
expect_s_client "TLS 1.2" ok -tls1_2
expect_s_client "TLS 1.3" ok -tls1_3
expect_s_client "TLS 1.2 with a CBC, SHA-1 cipher" "alert handshake failure" \
    -tls1_2 -cipher 'ECDHE-ECDSA-AES128-SHA:@SECLEVEL=0'
kill "$https_pid" 2>/dev/null || true
wait "$https_pid" 2>/dev/null || true
if ((tls_probe_status != 0)); then
    cat "$tmp/tls_probe.log"
    exit 1
fi

step "Server must-not-build fixtures (M3-032, M3-044)"
for fixture_s in "${serve_fixtures[@]}"; do
    expected_s="$(sed -n 's/^# Expected diagnostic (checked by scripts\/check_flare.sh): //p' "$fixture_s")"
    if [[ -z "$expected_s" ]]; then
        echo "error: $fixture_s states no expected diagnostic" >&2
        exit 1
    fi
    if "${FLARE[@]}" build -I src -I "$adapter" "$fixture_s" -o "$tmp/should_not_build" >"$tmp/log" 2>&1; then
        echo "error: $fixture_s built" >&2
        exit 1
    fi
    if ! grep -qF "$expected_s" "$tmp/log"; then
        cat "$tmp/log" >&2
        echo "error: $fixture_s failed without '$expected_s'" >&2
        exit 1
    fi
    echo "ok: $fixture_s"
done

# M3-002 headers evidence (docs/history/architecture-decisions.md "Headers decision (M3-002)"):
# a self-checking probe of what pinned Flare preserves in request and
# response headers over loopback, and candidate D's fixture (a Flare
# HeaderMap cannot be a field of Muntin's Copyable Request).
step "Flare header probe (M3-002)"
probe_status=0
./build/flare_header_probe >"$tmp/header_probe.log" 2>&1 || probe_status=$?
cat "$tmp/header_probe.log"
leftover_probe='^\./build/flare_header_probe$'
if pgrep -f "$leftover_probe"; then
    pkill -KILL -f "$leftover_probe" || true
    echo "error: the header probe left a server process behind" >&2
    exit 1
fi
if ((probe_status != 0)); then
    echo "error: Flare header behavior differs from the recorded M3-002 evidence" >&2
    exit 1
fi

step "inbound header mapping rule against Flare (M3-002)"
if ! out="$(./build/inbound_rebuild 2>&1)"; then
    printf '%s\n' "$out"
    echo "error: the inbound header mapping rule failed" >&2
    exit 1
fi
printf '%s\n' "$out"
if ! grep -qE 'Summary .* [1-9][0-9]* tests run' <<<"$out"; then
    echo "error: compat/flare/headers/inbound_rebuild.mojo ran no tests" >&2
    exit 1
fi

# M3-066 (docs/history/architecture-decisions.md "Request header conversion
# decision (M3-066)"): the four pieces per field that Flare's
# `HeaderMap.write_to` writes, which the chosen rebuild reads, and its
# prototype against the adapter's current conversion.
step "HeaderMap.write_to pieces and their rebuild (M3-066)"
if ! out="$(./build/write_to_pieces 2>&1)"; then
    printf '%s\n' "$out"
    echo "error: Flare's HeaderMap.write_to no longer writes the pieces M3-066 relies on, or their rebuild differs" >&2
    exit 1
fi
printf '%s\n' "$out"
if ! grep -qE 'Summary .* [1-9][0-9]* tests run' <<<"$out"; then
    echo "error: compat/flare/headers/write_to_pieces.mojo ran no tests" >&2
    exit 1
fi

step "candidate D: Flare HeaderMap in a Copyable Request (must not build)"
fixture_d=compat/flare/headers/headermap_in_request.mojo
expected_d="$(sed -n 's/^# Expected diagnostic (checked by scripts\/check_flare.sh): //p' "$fixture_d")"
if "${FLARE[@]}" build -I src "$fixture_d" -o "$tmp/should_not_build" >"$tmp/log" 2>&1; then
    echo "error: $fixture_d built" >&2
    exit 1
fi
if ! grep -qF "$expected_d" "$tmp/log"; then
    cat "$tmp/log" >&2
    echo "error: $fixture_d failed without '$expected_d'" >&2
    exit 1
fi
echo "ok: $fixture_d"

# M3-008 JSON evidence (docs/history/architecture-decisions.md "JSON codec decision (M3-008)"):
# the request and response fields and body bytes the JSON contract relies on,
# over loopback through the adapter, with the decision spike's Json[T].
step "Flare JSON loopback probe (M3-008)"
json_status=0
NO_PROXY=127.0.0.1 ./build/json_loopback_probe >"$tmp/json_probe.log" 2>&1 || json_status=$?
cat "$tmp/json_probe.log"
leftover_json='^\./build/json_loopback_probe$'
if pgrep -f "$leftover_json"; then
    pkill -KILL -f "$leftover_json" || true
    echo "error: the JSON probe left a server process behind" >&2
    exit 1
fi
if ((json_status != 0)); then
    echo "error: Flare JSON behavior differs from the recorded M3-008 evidence" >&2
    exit 1
fi
if ! grep -qE 'Summary .* [1-9][0-9]* tests run' "$tmp/json_probe.log"; then
    echo "error: compat/flare/json/json_loopback_probe.mojo ran no tests" >&2
    exit 1
fi

# M3-026 HEAD evidence, re-pinned by M3-027 (docs/history/architecture-decisions.md "HEAD decision (M3-026)"):
# what pinned Flare and the adapter send for a HEAD response over HTTP/1.1
# and h2c, by where the content is dropped.
step "Flare HEAD probe (M3-026, re-pinned by M3-027)"
head_status=0
./build/head_probe >"$tmp/head_probe.log" 2>&1 || head_status=$?
cat "$tmp/head_probe.log"
leftover_head='^\./build/head_probe$'
if pgrep -f "$leftover_head"; then
    pkill -KILL -f "$leftover_head" || true
    echo "error: the HEAD probe left a server process behind" >&2
    exit 1
fi
if ((head_status != 0)); then
    echo "error: Flare HEAD behavior differs from the recorded M3-026/M3-027 evidence" >&2
    exit 1
fi

# M3-038 body evidence (docs/history/architecture-decisions.md "Request body bytes decision (M3-038)"):
# what pinned Flare hands a handler of its own as the request body over
# HTTP/1.1 and h2c, and what Request.text() and String(from_utf8=) make of it.
step "Flare request body probe (M3-038)"
body_status=0
./build/body_probe >"$tmp/body_probe.log" 2>&1 || body_status=$?
cat "$tmp/body_probe.log"
leftover_body='^\./build/body_probe$'
if pgrep -f "$leftover_body"; then
    pkill -KILL -f "$leftover_body" || true
    echo "error: the body probe left a server process behind" >&2
    exit 1
fi
if ((body_status != 0)); then
    echo "error: Flare body behavior differs from the recorded M3-038 evidence" >&2
    exit 1
fi
if ! grep -qE 'Summary .* [1-9][0-9]* tests run' "$tmp/body_probe.log"; then
    echo "error: compat/flare/body/body_probe.mojo ran no tests" >&2
    exit 1
fi

# M3-056 streaming evidence (docs/history/architecture-decisions.md
# "Streaming responses and cancellation decision (M3-056)"): what pinned
# Flare does with a streamed response on the path Server serves: framing,
# a client that goes away, other connections, a quiet source, a raise.
step "Flare streaming probe (M3-056)"
stream_status=0
./build/stream_probe >"$tmp/stream_probe.log" 2>&1 || stream_status=$?
cat "$tmp/stream_probe.log"
leftover_stream='^\./build/stream_probe$'
if pgrep -f "$leftover_stream"; then
    pkill -KILL -f "$leftover_stream" || true
    echo "error: the stream probe left a server process behind" >&2
    exit 1
fi
if ((stream_status != 0)); then
    echo "error: Flare streaming behavior differs from the recorded M3-056 evidence" >&2
    exit 1
fi
if ! grep -qE 'Summary .* [1-9][0-9]* tests run' "$tmp/stream_probe.log"; then
    echo "error: compat/flare/stream/stream_probe.mojo ran no tests" >&2
    exit 1
fi

step "default environment excludes Flare"
for src in "$fixture" "$adapter_tests" "$serve_probe" "$roundtrip" "$server_tests" "$tls_tests" "$tls_probe" "$stop_driver" "$example" "$tls_example" "${serve_fixtures[@]}" compat/flare/headers/flare_header_probe.mojo compat/flare/headers/inbound_rebuild.mojo compat/flare/headers/write_to_pieces.mojo compat/flare/json/json_loopback_probe.mojo compat/flare/head/head_probe.mojo compat/flare/body/body_probe.mojo compat/flare/stream/stream_probe.mojo; do
    if "${DEFAULT[@]}" build -I src -I "$adapter" "$src" -o "$tmp/should_not_build" >"$tmp/log" 2>&1; then
        echo "error: $src built in the default environment; Flare leaked into it" >&2
        exit 1
    fi
    if ! grep -q "unable to locate module 'flare'" "$tmp/log"; then
        cat "$tmp/log" >&2
        echo "error: default-environment build of $src failed for a reason other than missing Flare" >&2
        exit 1
    fi
done
echo "ok: module 'flare' is not available in the default environment"
