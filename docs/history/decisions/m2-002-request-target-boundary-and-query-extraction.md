# Request target boundary and query extraction (M2-002)

> **Current.** Now described in [routing reference, "Matching"](../../reference/routing.md#matching) and [route-values reference, "Query values"](../../reference/route-values.md#query-values).
> Changed in part since:
> - [M2 handler storage decision](m2-handler-storage-decision.md): the storage reassessment (Variant arm counts) became moot when the Variant was replaced.
> - [M3-018](m3-018-route-value-decoding-and-string-route-values-decision.md): query values are percent-decoded once at capture (was: no decoding).
> - [M3-022](m3-022-several-route-values-decision.md): up to two route values per handler; a literal's query keys must be distinct.
> - [M3-039](m3-039-request-target-and-method-bytes-decision.md): the Flare adapter no longer passes any target verbatim: a target that is not UTF-8 is its 400.
> Its pointers into documents that were split or renamed since (`docs/DX.md`, old `docs/ARCHITECTURE.md` headings) are mapped in [the list of records](../architecture-decisions.md#documents-older-records-cite).

```text
raw request target ("/users/42?x=1")       TestClient.get(target) | Flare url, verbatim
        |
Request(method, target, body)               muntin/http.mojo: split at the first '?'
        |-- path  "/users/42"   -> route matching (App.handle)
        '-- query "x=1"         -> query extraction for a route's {key} (App.handle)
```

The split is owned by `Request.__init__`, the one constructor every backend already calls with the raw target, so the in-memory and Flare backends cannot diverge: neither splits, parses nor decodes the query. The Flare adapter's code is unchanged; it does not use Flare's own query helpers. `query` is stored raw (no `?`, `""` when absent); `#` is not special. Requests own `path` and `query` as separate `String`s, copied once at construction.

A route literal is split the same way at registration: `_Route` stores the path part (matched as in M2-001) and the key of its `{key}` query item, if any. `App.get` checks both parts at compile time (`_path_params`, `_query_params`) and requires their placeholder total to equal the handler's arity. At dispatch, the query never affects which route is selected; for an `Int` route with a query key, `_query_value` finds the key in `Request.query` (pairs split on `&`, key/value on the first `=`, byte-equal keys, no decoding) and the value goes through the same `_parse_int` as a path segment. A missing or duplicated key or a failed conversion is 400 `Bad Request` and the handler is not called.

Storage reassessment: M2-002 adds **no** `Variant` arm. The handler shape is still `def(Int) thin -> String`; whether the `Int` comes from a path segment or a query key is route data (`query_key`), not part of the shape. So the arm count grows with distinct parameter-type lists and return types, not with parameter sources. The next items would add arms: a `String` query value (DX section 3's `search(query: String)`) is one arm `def(String) thin -> String`; a path and a query value in one handler is `def(Int, Int) thin -> String`; each new Muntin-known return type (`-> Response`) multiplies the existing arms by one. With two parameter types, arity up to two and two return types that would have been 2 x (1 + 2 + 4) = 14 arms, each needing an `isa` branch in `App.handle`. An application-defined return or body type (`-> User`) is not one more factor: a library-side arm set cannot name it (next section).

`App.handle(Request) -> Response` is unchanged and remains the backend seam; streaming or async may change it later.
