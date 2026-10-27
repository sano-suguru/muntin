# Text and JSON body limits decision (M3-089)

> **Current.** Built by M3-090. Now described in [body size limits reference](../../reference/body-limits.md#body-size-limits), [routing reference, "Order of checks"](../../reference/routing.md#order-of-checks) and [ARCHITECTURE, "JSON"](../../ARCHITECTURE.md#json).

Status: **decision** (M3-089, issue [#143](https://github.com/sano-suguru/muntin/issues/143)). Evidence: its pull request. Changes part of M3-008 and M3-043 (below).

**Question and what settles it.** [M3-043](m3-043-typed-binary-request-body-size-limits-decision.md) left out text bodies, an `App`-wide or per-registration limit and a configurable `Json[T]` cap, whose fixed 1 MiB ([M3-008](m3-008-json-codec-decision.md)) a raw handler's `Json[T].from_body` also applies. How does an application bound a `FromBody` body and choose a `Json[T]` cap per route, answered 413 before the conversion: unit, spelling, default, order; and does it leave room for [#193](https://github.com/sano-suguru/muntin/issues/193)? A per-route receive limit and one refusal status across protocols stay under [M3-044](m3-044-server-receive-body-limit-decision.md)'s conditions. Settled by Mojo 1.1.0 probes; a scratch copy of production through `check.sh`, `test.sh`, `check_flare.sh` and a spike under AddressSanitizer; and a fresh-context review.

**Choice: the body type's `max_bytes`, 1 MiB by default for text; `Json[T, limit=n]`.**

```mojo
struct Article(FromBody):
    comptime max_bytes = 8 << 20   # none declared: 1 MiB; Int.MAX: none
    ...

def create(body: Json[NewNote, limit=64 * 1024]) -> Json[Note]: ...
```

- `FromBody` gains `comptime max_bytes: Int = 1_048_576`, read as `FromBytes`'s: over it is 413 after the route values, before the UTF-8 read, the carrier's rebuild and `from_body`. Text routes that took any length now answer 413 above 1 MiB. A negative value, on any body type, is rejected at registration.
- `Json` gains a keyword-only `limit` (default 1 MiB), its `max_bytes`: 415, then 413, then the 400s, as now; `Json[T, limit=n].from_body` raises above it. At most 2^32 − 1 (the parser's `UInt32` offsets), checked where it is instantiated; `float()` reads an exponent's digits up to a cap kept above it (a literal's digits shift its exponent by up to its length). Parse memory grows with the limit. On a result it means nothing.
- The default fails closed: a type that declares nothing or misspells the member gets 1 MiB, never none. The owner chose it over a required member.

**Rejected.**
- A required member, as `FromBytes`: a line in about 180 text types; its gain, a family default in a refining trait, is our one cost.
- A default of `Int.MAX`: fails open on a typo (M3-043).
- An `App`-wide or per-registration limit: M3-043's reasons.
- The limit on `T`: a top-level `List` has nowhere to declare it.
- A positional `limit`: a second parameter would depend on its position.

**For #193.** A JSON body rule chosen per route is another keyword-only `Json` parameter; an `App`-wide rule stays open.

**Revisit when** text bodies need a family default; `Json` needs a second such parameter (each one makes `Json[T, limit=n]` a type a handler must repeat to return); streaming bodies are decided.

**Next production slice (M3-090):** the prototype at `35380d2` (its `prototype-m3-089/README.md`).
- Code: as prototyped.
- Tests: the spike's cases in the body, JSON and limit suites, every shape and method; its fixtures, with a revisit index row; the three tests pinning unlimited text bodies, rewritten; a literal of 10^9 digits whose exponent passes 10^9 reading 0.0, not 1.0; mutations (`>` as `>=`, each 413 check removed or after the UTF-8 read, the upper bound removed, the exponent cap back at 10^9); the whole-output comparison; the loopback JSON 413 case extended to a text body.
- Docs: bodies, routing ("Order of checks"), serving ("Receive body limit"), guide, `docs/ARCHITECTURE.md`, `docs/SPEC.md`.
