# Headers decision (M3-002)

> **Current.** Now described in [headers reference](../../reference/headers.md), [headers reference, "Through the Flare adapter"](../../reference/headers.md#through-the-flare-adapter) and [ARCHITECTURE, "Request handling"](../../ARCHITECTURE.md#request-handling).
> Changed in part since:
> - [M3-040](m3-040-binary-request-and-response-bodies-decision.md): R1 raw transport: the body left the raw arguments, so fields follow method, path and query (not four strings).
> Its pointers into documents that were split or renamed since (`docs/DX.md`, old `docs/ARCHITECTURE.md` headings) are mapped in [the list of records](../architecture-decisions.md#documents-older-records-cite).

Status: **decision** (M3-002; production and adapters are unchanged in it). It decides how Muntin-owned `Request` and `Response` carry HTTP header fields, how raw handlers reach them, what the Flare adapter maps, and what stays out of the first production slice.

**Selected: A, `muntin.Headers`, an ordered list of fields.**

```mojo
struct Headers(Copyable, Movable, Sized):
    def add(mut self, name: String, value: String) raises      # appends; earlier same-name fields stay
    def set(mut self, name: String, value: String) raises      # removes every same-name field, then appends
    def get(self, name: String) -> Optional[String]            # first value; None when absent ("" is a value)
    def get_all(self, name: String) -> List[String]            # every value, in order
    def __len__(self) -> Int
    def name(self, i: Int) -> String                          # as received or added
    def value(self, i: Int) -> String
```

- **Fields:** one list of name/value pairs. Each field keeps its position and its name's original casing. A repeated name is several fields, in order (`Set-Cookie`, `Vary`, `X-A` then `x-a`). Lookup compares names ASCII case-insensitively. There is no list joining and no reordering.
- **Validation at insertion:**
  - Names must be RFC 9110 tokens (non-empty).
  - Values may contain anything except control bytes (0x00–0x1F except HTAB, and 0x7F), and may not begin or end with SP or HTAB (RFC 9110 field-value; a receiver would trim them). Bytes 0x80 and up are allowed as the UTF-8 a Mojo `String` holds.
  - `add` and `set` raise otherwise, so no field added through the API can carry CR, LF or NUL.
  - The accepted set covers what pinned Flare's strict HTTP/1.1 parser accepts inbound (tokens; VCHAR, SP, HTAB, trimmed at both ends).
- **Ownership:** `Copyable` with an explicit `.copy()`, not implicitly copyable (`headers_fail/implicit_copy.mojo`), like `Request` and `State`.
  - `Request` gains `headers: Headers`, and its initializer gains a last, defaulted argument, `var headers: Headers = Headers()`, which moves it in: a caller passes `headers^` or `headers.copy()`, and a plain variable is a compile error (`headers_fail/request_headers_moved_in.mojo`). Every existing `Request(method, target[, body])` call is unchanged.
  - `Response` gains `headers: Headers`, empty from `Response(status, body)` and `Response.text`.
  - A raw handler that borrows its request cannot change the request's headers (`headers_fail/borrowed_request_headers.mojo`); `var req` owns a copy and can.
- **Bytes:** values are `String`, holding valid UTF-8. Over HTTP/1.1, Flare's default (strict) configuration answers 400 itself to a header value with a byte ≥ 0x80, a control byte, obs-fold or whitespace before the colon, so Muntin sees only ASCII. Over cleartext HTTP/2, which the default server also accepts, Flare admits bytes ≥ 0x80, control bytes other than NUL/CR/LF, and names with `:` or bytes ≥ 0x80. Its HPACK decoder replaces invalid UTF-8 with U+FFFD (as Flare does for bodies), so that arrives replaced. The adapter's inbound rule (below) answers 400 to fields Muntin cannot represent (control bytes, non-token names) and keeps valid UTF-8. Arbitrary header bytes are not representable, a stated limitation.

**Raw handlers: R1, fields as raw argument strings.** For a raw route, `App.handle` appends each field's name and value, in order, after the four strings it already passes (method, path, query, body). `_call_raw` rebuilds a `Headers` with `add` (a failure is unreachable, because the fields came from a `Headers`; it would answer the fixed 500) and passes `Request(method, target, body, headers^)`.
- `_Call`, `_Erased`, `_Route`, the storage module and the unsafe surface are unchanged, as is `App.handle(Request) -> Response`'s signature. `App.handle`'s body grows one loop.
- Typed routes get no header strings (extraction is deferred), so their cost is nil.
- Cost on a raw route: one copy of each name and value per request, as bodies already have.
- Measured lossless through production `_Erased`: order across names, casing, `X-B` then `x-b`, empty values, a value with `:` and HTAB, and zero fields (`test_raw_transport_is_lossless_through_erased`). Each name and value is its own list element, so no delimiter is involved.
- R2, passing the `Request` through `_Call`, is rejected without a spike: the storage module must not name `Request` (`check_unsafe.sh`, M2-006), and R1 needs no storage change.

**Responses and defaults: no default headers (D0).** A handler returning `Response`, or a `ToResponse` result building one, sets fields on `response.headers`; a `String` result sets none. `Response.text` adds no `Content-Type`.
- So a response that sets no field keeps its wire headers. (A request whose fields Muntin cannot represent is answered 400 by the inbound rule below; before, the adapter discarded its fields and routed it.) Measured on a scratch copy with the slice applied: `GET /hello` through Flare still carries exactly Flare's own `Content-Length`, `Date` and `Connection: close` and no `Content-Type`, as before.
- A default `Content-Type` belongs with the codec decision (JSON), which needs it.

**Validation: V1, at insertion.** An invalid field fails at the line that adds it. In a raising handler that is a handler error: the fixed 500, or its `ToErrorResponse` (M2-011/M2-013).
- The cost: `add` raises, so non-raising code needs `try`. That includes `ToResponse.to_response`, which must stay non-raising (`headers_fail/add_in_non_raising_code.mojo`; the scratch `Created.to_response` wraps `add`).
- Rejected: V2, a non-raising `add` with `App.handle` checking every response afterwards (`UncheckedHeaders` and `seam_check` in the spike). It removes that `try`, but the error surfaces as an index after the handler returned instead of at the line that added it. (Both need the adapter's re-check below, so the per-response cost does not separate them.)
- Mojo 1.1.0 has no private fields, so `headers._fields.append(...)` bypasses `add` (`headers_known_gaps/internal_field_bypass.mojo`, must build). Fields are one list of pairs, so such a write cannot desynchronize names and values (a pair of lists could, and then crashed on an out-of-bounds index before any check ran). The backend is the second line: the adapter re-checks every outgoing field through `add` and answers the fixed 500 on failure. Flare itself rejects only CR and LF and would emit NUL, other control bytes or a non-token name raw.

**Flare mapping (pinned v0.11.0, measured by `compat/flare/headers/flare_header_probe.mojo`: 49 self-checking observations over HTTP/1.1 and cleartext HTTP/2, the latter with Flare's public HPACK encoder and decoder, run by `check_flare.sh`).**
- **Inbound.** Flare's `HeaderMap` keeps order, original casing, repeated names and empty values, and over HTTP/1.1 trims SP/HTAB around values.
  - It has no public iterator or index access (only `len`, `get`, `get_all`, `contains` by name), so the adapter rebuilds fields from the public `encode_to` (`name: value\r\n` per field) and never reads Flare's `_keys`/`_values`.
  - Over HTTP/1.1 that parses back exactly, because names are tokens. Over cleartext HTTP/2 a name may hold `:` after its first byte, and a parse at the first colon would forge a field: the client's `x-user:admin: zzz` read as `x-user` = `admin: zzz` (found by the review, measured over h2c).
  - The inbound rule therefore verifies the parse against Flare's by-name view. The parsed count must equal `len()`; per name, the parsed values must equal `get_all(name)` position by position; and every field must pass `Headers.add`. Any failure answers 400. Executed in `compat/flare/headers/inbound_rebuild.mojo`: HTTP/1.1-shaped fields rebuild exactly, including UTF-8 and `a: b`; a forged name is rejected alone and beside a real field with the same value; control bytes are rejected, and so is invalid UTF-8 as a lenient HTTP/1.1 configuration would deliver it (over HTTP/2 Flare has already replaced it with U+FFFD).
- **HTTP/2 request rewriting** (measured over h2c): Flare turns `:authority` into a first `Host` field and merges `cookie` fields into one, joined with `"; "`, moved to the end. It refuses (RST_STREAM) uppercase names, a space in a name, NUL/LF and leading or trailing SP/HTAB in values, and `connection`. Muntin receives what Flare's `HeaderMap` holds; these rewrites are Flare's.
- **Outbound.** The adapter appends each field in order with its casing, so repeats, empty values and `Set-Cookie` pairs reach the wire as set (over HTTP/2 Flare lowercases names, as the protocol requires).
  - It omits connection-specific and backend-owned fields on every protocol (`outbound_fields` in the spike):
    - `Content-Length`, `Transfer-Encoding`, `Connection`, `Keep-Alive`, `Proxy-Connection`, `Upgrade` and `TE`, which are connection-specific (RFC 9113 §8.2.2) or framed by the backend;
    - `Trailer`, because Muntin sends no trailers and an announcement of trailers would be false;
    - every field named in a `Connection` value (comma-separated tokens, OWS trimmed, case-insensitive): RFC 9110 §7.6.1 makes them hop-by-hop. Dropping only `Connection` would keep, say, `X-Hop: secret` while erasing the statement that it was connection-only, which changes its meaning.
  - Measured (the probe's `/hopout` and `/hoptoken`). Over HTTP/1.1, Flare drops only `Content-Length`, `Connection` and `Date`: it replaces a handler's `Connection` without reading its tokens, and it sends `Keep-Alive`, `Proxy-Connection`, `Upgrade`, `TE`, `Trailer` and the named `X-Hop`. It also passes `Transfer-Encoding` through beside its own `Content-Length` with an unchunked body, a malformed response. Over HTTP/2, Flare drops `connection`, `transfer-encoding`, `keep-alive`, `proxy-connection` and `upgrade`, but sends `te`, `trailer`, the named `x-hop`, and a handler's `content-length` unchanged (a wrong value with a shorter body is malformed, RFC 9113 §8.1.1), with no stream error. Flare's filters cover a different subset on each protocol, so the adapter applies one rule for both.
  - A handler's `Date` passes through over HTTP/2 and is replaced by Flare's over HTTP/1.1 (Flare-owned; not stripped by the adapter).
  - The fields are stripped, not answered with an error: the backend owns the connection, and Flare's own HTTP/2 path strips the same way.
  - The adapter never uses Flare's `set`, which rewrites only the first case-insensitive match and leaves later duplicates.
  - A `HeaderInjectionError` from Flare (unreachable after the re-check) answers 500.
- **What Flare cannot give Muntin.** Over HTTP/1.1 defaults: nothing a `String` model needs. Over HTTP/2: original name casing (lowercase on the wire), separate `cookie` fields (merged), the position of `:authority`, and fields Muntin rejects (400) rather than represents. Outbound, Muntin can express backend-owned fields that the adapter omits.

**Candidates** (Mojo 1.1.0 (8189361e), Flare v0.11.0):

| Candidate | Result | Verdict |
|---|---|---|
| A. `Headers`: ordered fields, original casing, ASCII case-insensitive lookup, validated `add`/`set`, `Optional` `get` | lossless for order, casing, repeats and empty values, through Muntin and through R1; Flare's strict inbound set fits; copies explicitly | **chosen** |
| B. `Dict[lowercase name, List[String]]` | regroups repeated names and loses casing: received `X-B, Content-Type, x-b` is emitted `x-b, x-b, content-type` (`test_candidate_b_loses_order_and_casing`) | rejected |
| C. one comma-joined value per name (RFC 9110 list rule) | `Set-Cookie` is not a list field and its `Expires` contains commas, so two cookies cannot be split back (`test_candidate_c_breaks_set_cookie`) | rejected |
| D. Flare's `HeaderMap` in `Request` | a backend type in the public API (A1), which decides it alone. Also measured: `Movable` only, so the compiler cannot synthesize `Request`'s copy (`compat/flare/headers/headermap_in_request.mojo`; a hand-written copy through `HeaderMap.copy()` would work); `get` returns `""` for absent and empty alike; first-match `set` | rejected |
| V2. non-raising `add`, checked at `App.handle` | the error loses its line; dispatch gains a header check | rejected (V1 chosen) |
| R2. `_Call` carries the `Request` | the storage module would name `Request` (guarded) | rejected (R1 chosen) |

**Typed extraction: deferred.** Typed handlers read no headers in the first slice. A typed result sets headers through `Response`, which is enough for the coherent model above. Header extraction would compete for M3-001's single injected slot (or need a new binding rule), so it needs its own decision. Middleware, CORS and authentication are not designed here.

**Testing.** `TestClient` gains nothing in the first slice. Header tests build `Request(method, target, body, headers^)` and call `App.handle`, the seam `TestClient` uses. In-memory and Flare differ in these cases:
- connection-specific and backend-owned fields, and fields a `Connection` value names, stay in an in-memory `Response` but are omitted on the wire; over HTTP/1.1 a handler's `Date` is replaced by Flare's;
- an internal-name bypass passes in memory but is a 500 on the wire;
- a request field Muntin cannot represent never exists in memory (`Headers.add` rejects it), while over HTTP/2 Flare admits it and the adapter answers 400;
- over HTTP/2, Flare lowercases response names and rewrites request fields as above.

**Evidence.**
- `tests/headers_spike.mojo` + `tests/test_spike_headers.mojo` (12): order, casing and repeats; case-insensitive lookup; empty values; `set`; validation (CR/LF, NUL, DEL, non-token names, leading/trailing SP/HTAB; inner HTAB, `:` and UTF-8 accepted); explicit copies; defaults adding nothing; R1 through production `_Erased`; B's and C's losses; V2's deferred error; the outbound rule (connection-specific and `Connection`-named fields stripped, order kept).
- `tests/headers_lib_only/driver.mojo`: built by `check.sh` without the application module.
- `tests/headers_fail` (5): borrowed request, `add` in non-raising code, implicit copy, `Optional` `get`, headers moved into `Request` (`^` required).
- `tests/headers_known_gaps/internal_field_bypass.mojo` (must build).
- `compat/flare/headers/flare_header_probe.mojo` (49 observations over raw loopback TCP: HTTP/1.1 on default and obs-text-lenient servers, cleartext HTTP/2 on the default server, hop-by-hop response fields on both), `inbound_rebuild.mojo` (the inbound rule, 3 tests) and `headermap_in_request.mojo` (must not build), all in `check_flare.sh`.
- Mutations (planted, reverted; 16), each red: in the spike, names lowercased on store; dedupe on add; Flare-style first-match `set`; case-sensitive lookup; an empty value treated as absent; R1 dropping empty values; R1 reversing order; value validation removed; HTAB rejected; leading/trailing whitespace allowed; a default header on `Request`; in the inbound rule, the verification against `len`/`get_all` removed (the forged name and invalid UTF-8 get through); in the outbound rule, `Connection`-named fields kept, `Upgrade` kept, `TE`/`Trailer` kept, `Connection` tokens untrimmed.
- Scratch copy of this branch with the slice applied (not retained): `Headers` in `http.mojo` and exported, the two fields, R1 in `App.handle` and `_call_raw`, the Flare mapping above.
  - `./scripts/check.sh`, `./scripts/test.sh` (every suite's count unchanged, plus 4 scratch tests) and `./scripts/check_flare.sh` (plus one loopback test) exit 0.
  - The 90 production fixtures' diagnostics (`compile_fail`, `storage_fail`, `body_fail`, `state_get_fail`) are identical.
  - Over HTTP/1.1 loopback, `X-Signature` and repeated `X-A`/`x-a` reach a raw handler. Two `Set-Cookie`, an empty value and `X-Request-Id` come back. `Transfer-Encoding` is omitted. An injection attempt is 500 in memory and on the wire, and an internal-list bypass is 500 on the wire. (The scratch copy predates the review's h2c finding. Its inbound mapping split at the first colon without verification; the inbound rule above replaces it and is executed in `inbound_rebuild.mojo`.)

**Revisit when:**
- typed header extraction is proposed: decide its binding (it competes for the single injected slot) before adding it;
- a codec (JSON) is decided: decide the default `Content-Type` and whether `Response.text` gains one (that changes existing wire bytes);
- `ToResponse` implementations that set headers prove common: consider a non-raising way to add fields known valid;
- Flare exposes a public field iterator: map inbound fields through it instead of parsing `encode_to`;
- a backend or Flare configuration accepts obs-text: the U+FFFD replacement becomes observable, so decide whether bytes need a representation;
- Mojo gets private fields: the internal-name bypass closes, and the adapter's re-check can be reconsidered;
- `flare_header_probe.mojo` fails: Flare's header behavior changed; re-measure the mapping;
- Flare's HTTP/2 path validates names as tokens, or exposes a public field iterator: the inbound verification can be simplified;
- Muntin gains trailers or streaming responses: decide `Trailer` and `TE` instead of omitting them.

**Next production slice (M3-005): headers in production.** Implemented as listed ("Headers in production (M3-005)" below).
- `src/muntin/http.mojo`: `Headers` as in the spike (validation helpers private), `Request.headers` with the defaulted `var headers` initializer argument, and `Response.headers`. `muntin` exports `Headers`.
- `src/muntin/app.mojo`: in `App.handle`, a raw route appends each field's name and value after the four strings. `_call_raw` rebuilds `Headers` with `add`; a failure is the fixed 500. Typed routes are unchanged.
- `adapters/flare/muntin_flare.mojo`:
  - inbound fields rebuilt from `encode_to` and verified as in `inbound_rebuild.mojo` (count equals `len()`, per-name values equal `get_all` by position with ASCII case-insensitive names, each passes `add`); any failure answers 400. The check is quadratic in the number of fields, which Flare's 8 KB header limit bounds;
  - outbound fields filtered by the outbound rule (`Content-Length`, `Transfer-Encoding`, `Connection`, `Keep-Alive`, `Proxy-Connection`, `Upgrade`, `TE`, `Trailer` and every `Connection`-named field omitted), appended in order, each re-checked through `add`, with a failure or `HeaderInjectionError` answering 500;
  - the module comment updated.
- Unchanged: `_Call`, `_Erased`, `_Route`, the storage module, the unsafe surface, `App.handle`'s signature, `TestClient`, `Response.text` (no default headers) and every existing test, fixture and expected text.
- Tests: the spike's semantics on production `Headers`; raw handlers reading and writing headers through `App.handle`; a typed `ToResponse` result setting a header; existing routes setting none. Loopback through Flare covers request fields (order, casing, repeats, empty values), response fields (`Set-Cookie` twice, an empty value), `Transfer-Encoding` omitted, an injection attempt as 500, `GET /hello`'s headers unchanged, over h2c a forged `x-user:admin` name answered 400, and `Connection: X-Hop` with `X-Hop` omitting both on HTTP/1.1 and h2c. Production fixtures counterpart to `tests/headers_fail`.
- Docs: DX section 9's webhook reads `req.headers.get("x-signature")`, and DX gains a headers section.
- Not in the slice: typed header extraction, a default `Content-Type`, `TestClient` header methods, middleware, CORS and authentication.
