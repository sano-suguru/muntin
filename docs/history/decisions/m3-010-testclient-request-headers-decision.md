# TestClient request headers decision (M3-010)

> **Current.** Now described in [testing reference, "`TestClient`"](../../reference/testing.md#testclient).
> Changed in part since:
> - [M3-040](m3-040-binary-request-and-response-bodies-decision.md): a positional Headers on TestClient.post is now `no matching method`, not `invalid call ... unexpected argument` (bytes overloads added).
> Its pointers into documents that were split or renamed since (`docs/DX.md`, old `docs/ARCHITECTURE.md` headings) are mapped in [the list of records](../architecture-decisions.md#documents-older-records-cite).

Status: **decision** (M3-010; `src/muntin` and `adapters/` are unchanged in it; production since M3-011, "TestClient request headers in production (M3-011)" below). It decides how `muntin.testing.TestClient` sends request header fields, so that a test can reach a `Json[T]` body route through the client instead of `App.handle(Request(..., headers^))`.

**Selected: K, a keyword-only, defaulted `headers` argument on the existing `get` and `post`.**

```mojo
struct TestClient[origin: Origin[mut=False]]:
    def get(self, target: String, *, var headers: Headers = Headers()) -> Response
    def post(self, target: String, body: String, *, var headers: Headers = Headers()) -> Response
```

```mojo
var client = TestClient(app)
client.get("/hello")                          # unchanged
client.post("/users", "name=Ada")             # unchanged

var headers = Headers()
headers.add("Content-Type", "application/json")
client.get("/echo", headers=headers.copy())                 # headers stays usable
client.post("/users", '{"name":"Ada"}', headers=headers^)   # moved
```

- **What the client does:** builds `Request(method, target, body, headers^)` and calls `App.handle`; nothing else. It adds, removes, inspects or merges no field, and it knows nothing of JSON or of the route. A request sent through it is the request `App.handle(Request(...))` receives from the same arguments, so the answers are equal (status, body and response fields).
- **Ownership:** the argument is `var headers: Headers`, moved into the `Request`, as `Request`'s own initializer takes it (M3-002): a caller passes `headers=headers^` or `headers=headers.copy()`; a plain variable is `cannot be implicitly copied`, and using the variable after `^` is `use of uninitialized value`. A copy sent earlier is unaffected by later changes to the original. The default is a new, empty `Headers` on every call.
- **Reading a call:** a request that carries fields says `headers=` at the call, on every method; one that does not, carries none. A positional `Headers` (or a string) after the target, or after the body, is `invalid call to 'get'` / `'post'`: `unexpected argument`. Keyword-only is chosen over a positional last argument because `client.get("/users", h^)` does not say what its second argument is, while `client.get("/users", headers=h^)` does; it is chosen on both methods, rather than on `get` alone, so that one rule holds on every method whether or not it takes a body. It does not mirror `Request`'s argument positions, which the client does not reproduce anyway (it hides the method, and `get` hides the body).
- **Why the surface is minimal, and why K among the equal-cost shapes:** two existing signatures each gain one defaulted parameter. No method, overload, type, field or client state is added; `App`, the registration overloads, `Request`, `Headers`, the JSON code and the Flare adapter are untouched. P and H work as well and have the same surface; K is chosen among them for the readability and the single rule above, not for size or because the measurements force it.
- **Compatibility:** existing calls `client.get(target)` and `client.post(target, body)` keep their spelling and meaning (existing call-site compatibility, measured below). This does not claim compatibility for code that treats the methods as values with their previous exact function signatures. (On Mojo 1.1.0 a bound method value, `var f = client.get`, does not compile on `main` either: `member method closures are not supported`.)

**Rejected (measured on Mojo 1.1.0 in scratch copies of `src/muntin`; production unchanged):**

| Candidate | Measured | Why rejected |
|---|---|---|
| status quo: no client API; JSON body tests call `App.handle(Request(..., headers^))` | what `main` does (`tests/test_json.mojo`, `tests/test_json_dx.mojo`) | a request that needs a field cannot go through the client at all, so the client cannot test a `Json[T]` body route except as 415 |
| P: positional last `var headers: Headers = Headers()` on both | builds; `client.get("/echo", h^)`, `client.post("/echo", "b", h^)` and the `headers=` spelling work; existing callers pass | `client.get("/users", h^)` does not show what its second argument is; one keyword makes every call with fields explicit at the cost of `headers=` |
| H: keyword-only on `get`, positional last on `post` | builds; `client.get("/x", headers=h^)` and `client.post("/x", body, h^)` work, positional on `get` is `unexpected argument`; existing callers pass | the spelling would depend on whether the method takes a body; K gives `get` the same readability with one rule |
| borrowed: `headers: Headers = Headers()`, copied inside | builds; existing callers pass; `client.post("/echo", "b", h)` with a plain variable compiles, and the client copies it | `Request` takes headers by move and rejects a plain variable (`headers_api_fail/request_headers_moved_in.mojo`); the client would accept what `Request` refuses and copy behind the call |
| B: separate overloads `get(target, var headers)` and `post(target, body, var headers)` beside the unchanged ones | builds; identical calls and results to P; existing callers pass | two more methods for exactly P's behavior |
| C1: client-level default fields (`client.headers`, sent on every request) | builds; with `client.headers.add("Content-Type", "application/json")`, `GET /echo` and a plain-text `POST /echo` both receive the field | the fields of a request are not visible at its call; needs a `var client`, per-client state and a merge rule for per-request fields |
| C2: builder (`client.request("POST", target).header(n, v).body(b).send()`) | builds only with `send(deinit self)`; `header` raises; `client.request("PUT", "/users").send()` is 404 | a new public type and four methods; it also opens arbitrary methods on the client, which is outside this item |
| D1: `post_json(target, body)` adding `Content-Type: application/json` | builds; sends the field to the non-JSON route `/echo` too | the client would know JSON; a JSON-only API where a general field argument suffices |
| D2: automatic `Content-Type` when `post`'s body looks like JSON | the same explicit target and body give 200 through the client and 415 through `App.handle(Request(...))` built from them (and over a connection without the field); `/echo` receives a field nobody sent | the client silently changes the `Request` by adding a field the caller did not supply, so its answers differ from every backend's; it hides the M3-008 request rule from the tests meant to exercise it |

**M3-008's revisit condition** "`TestClient` gains a way to send header fields" is the one this decision meets. Its outcome: the request rule is unchanged (a `Json[T]` body needs exactly one `Content-Type` whose media type is `application/json`, otherwise 415), and the accepted cost it recorded ends with the production slice: a test reaches a JSON body route through the client by sending the field. `TestClient.post(target, body)` without it is still 415, so `tests/test_json.mojo`'s pins of that stay true.

**Invariants:**
- `TestClient` builds a Muntin `Request` and calls `App.handle`, nothing else: it adds, removes, inspects or merges no field and never looks at the body or the route. Its answer equals `App.handle(Request(method, target, body, headers))` for the same arguments.
- The bare forms `client.get(target)` and `client.post(target, body)` keep their spelling and meaning: no field is sent.
- The headers argument of `get` and `post` is keyword-only, defaulted to an empty `Headers`, and moved in as `Request`'s initializer moves it; there is no implicit copy and no per-client state. Pinned twice: `tests/testclient_headers_api_fail` pins the client's own spelling and ownership on production `TestClient` (keyword-only, no implicit copy, no use after `^`; `tests/testclient_headers_fail` pinned it on `SpikeClient` until M3-011), and `tests/headers_api_fail/request_headers_moved_in.mojo` pins the premise the client follows, that `Request` takes headers by move.
- No backend type reaches the client; the client stays in `muntin.testing`, outside the backend seam.

**Evidence** (files as of the M3-010 merge; M3-011 deletes the spike and its fixtures):
- `tests/testclient_headers_spike.mojo` (`SpikeClient`: K over production `App`, `Request` and `Headers`; `AutoTypeClient`: D2) and `tests/test_spike_testclient_headers.mojo` (9): the bare `get` and `post` equal production `TestClient` and `App.handle` (200, 404); fields on `GET` and on `POST`, a typed route unaffected by fields; repeated names (`X-A`, `Set-Cookie`, `x-a`, `Set-Cookie`) in order and casing; an empty value present as `""` and distinct from an absent field; `.copy()` leaving the original usable and a later change not reaching a sent request, and `^`; the default empty on every call after calls with fields; a JSON body route 200 with `Content-Type: application/json` and `application/json; charset=utf-8`, 415 without the field (equal to today's `TestClient.post`), with `text/plain` and with two fields, 400 for malformed JSON; every case equal to `App.handle(Request(...))`; D2's parity break.
- `tests/testclient_headers_fail` (4, `check.sh`): a plain variable (`cannot be implicitly copied`), use after `^` (`use of uninitialized value 'h'`), positional headers on `get` and on `post` (`invalid call to 'get': unexpected argument`, `invalid call to 'post': unexpected argument`).
- Existing call-site compatibility: scratch copies of `src/muntin` with K, P, H, the borrowed candidate and B in `testing.mojo` build every `tests/test_*.mojo` from `main` unchanged (273 tests, all pass, as on `main`). With K, every other file that calls `TestClient` also builds unchanged with `--Werror`: `main.mojo`, `tests/json_known_gaps/refining_trait_default.mojo`, and in the `flare` environment `adapters/flare/test_muntin_flare.mojo` (13 pass) and `test_localhost_roundtrip.mojo` (6 pass), beside the other `check_flare.sh` builds. No must-fail fixture calls `TestClient`, so no expected diagnostic can change.
- Mutations of `SpikeClient` (7), each red: fields dropped in `get`, dropped in `post`, `get` sent as `POST`, the body dropped, a field added by `post` (inside a `try`, since `add` raises) (each fails tests); the `*` dropped from `get`, from `post` (each makes its positional fixture build).

**Cost:** one defaulted keyword parameter on each of two methods; a call with fields spells `headers=`. A test that needs fields builds a `Headers` value first, in a raising context (`add` raises); there is no one-line literal for fields.

**Revisit when:**
- `Request`'s initializer changes its ownership of headers (for example, from move to borrow, which `tests/headers_api_fail/request_headers_moved_in.mojo` building would show): revisit whether the client should follow it;
- a fixture in `tests/testclient_headers_api_fail` (in M3-010, `tests/testclient_headers_fail`) builds: the client's spelling or ownership changed;
- `TestClient` gains another request method: revisit whether its header spelling should follow this pattern, keeping it consistent while it stays ergonomic;
- `Headers` gains an inline literal (a Mojo collection literal or a Muntin initializer): consider accepting it without changing the bare forms;
- a test needs the same fields on most requests: a helper in the test, not client state, unless several suites repeat it.

**Next production slice (M3-011): TestClient request headers.**
- `src/muntin/testing.mojo`: `get(self, target: String, *, var headers: Headers = Headers())` sends `Request("GET", target, "", headers^)`; `post(self, target: String, body: String, *, var headers: Headers = Headers())` sends `Request("POST", target, body, headers^)`; `Headers` imported from `.http`; docstrings say the fields are moved in and none are sent by default. Nothing else in `src/muntin` or `adapters/` changes.
- Tests: `tests/test_testclient_headers.mojo`, the spike's semantics on production `TestClient` (bare forms equal to `App.handle`; fields on `GET` and `POST`; repeated names in order and casing; empty value; `.copy()` and `^`; default empty on every call; JSON body route 200 with the field and 415 without, `text/plain` and two fields; malformed 400; each equal to `App.handle(Request(...))`). `tests/test_json_dx.mojo` sends DX section 4's successful JSON bodies through `client.post(target, body, headers=headers^)`, compares one of them with `App.handle(Request(...))`, and keeps its `TestClient(app).post("/users", ok)` 415 pin (no field sent). `tests/test_json.mojo`'s `TestClient.post` 415 pins stay.
- Negative fixtures: `tests/testclient_headers_api_fail` against production `TestClient` (plain variable, use after `^`, positional headers on `get`, positional headers on `post`), registered in `check.sh`.
- Spike retirement: the production tests and fixtures take over, so the slice deletes `tests/testclient_headers_spike.mojo`, `tests/test_spike_testclient_headers.mojo` (`AutoTypeClient` included) and `tests/testclient_headers_fail`, removes the latter from `check.sh`, and points the `docs/ARCHITECTURE.md` revisit-index row at `tests/testclient_headers_api_fail` (keeping `tests/headers_api_fail/request_headers_moved_in.mojo`). This record keeps what they measured.
- Mutations (in scratch copies of `src/muntin`), each red: fields dropped in `get`; dropped in `post`; `get` sent as `POST`; the body dropped; a field added by the client; the `*` dropped from `get`; from `post`.
- Diagnostics: every existing expected diagnostic identical (no `App` signature changes).
- Docs: every statement that the client sends no header fields changes to the argument: `docs/DX.md` the status table, "Still targets", section 4's JSON bullet (its example sends the field through the client), and the `TestClient` statements in sections 9, 10 and 19; `docs/ARCHITECTURE.md` "Current architecture": "Backend seam" (`TestClient.get(target)` and `.post(target, body)` send no header fields), "JSON" (`TestClient.post` sends no fields) and "Other current limits" (`TestClient` header methods). Also `docs/SPEC.md`, `feature_list.json`, `AGENT_PROGRESS.md`.
- Done: the above; `check.sh`, `test.sh`, `check_flare.sh` and `git diff --check` exit 0; CI `verify` and `flare` pass; a fresh-context review finds no unresolved material issue.
- Not in the slice: JSON-specific client methods or automatic fields, client-level default fields, a builder, new client methods or HTTP methods, typed header extraction, any change to the 415 rule, `Request` or `Headers`.
