# Registration complexity budget decision (M3-052)

> **Current.** Now described in [ARCHITECTURE, "Registration surface"](../../ARCHITECTURE.md#registration-surface).

Status: **decision, standing constraint** (M3-052, pull request #96; `src/muntin` unchanged). The overload counts, build-time measurements and probes are in the pull request.

**Question and what settles it.** An outside review asked how much internal complexity typed registration may take for `app.get[path](handler)`: forty overloads (eight per method name, five names), and whether that makes new methods, new parameter kinds, more parameters, build time, diagnostics or Mojo upgrades harder, so that growth needs a limit. Settled by the overload count and its history; cold `mojo build` times on Mojo 1.1.0 as the number of routes, the slot arity, the methods used and the declared overload set vary; and whether Mojo 1.1.0 can express one shared registration mechanism behind the current spelling.

**Choice: keep the structure ([M3-014](m3-014-registration-structure-decision.md), [M3-020](m3-020-http-methods-decision.md), [M3-022](m3-022-several-route-values-decision.md)) and make its size a budget that only a decision raises.** The count went 20, 12 (M3-015), 30 (M3-020's methods), 40 (M3-022's slot arity 3), and has not moved since, while optional values, typed binary bodies, binary bodies with header fields, byte limits, bodyless `post`, `put` and `patch` and named values shipped as slot kinds or rules. In the measured range (1 to 200 routes; eight against forty declared overloads), build time grew with the number of routes, and the declared overload count made no difference distinguishable from measurement noise; whether slot arity has an effect of its own is unsettled. So the known costs of more overloads are source size, copies that each rule change touches, and diagnostics. The budget:
- each method name has at most eight overloads, slot arities 0 to 3, in the stateless and the stateful family. This is a maintenance ceiling chosen here, not a compiler boundary: every candidate note is printed at eight, but a stateful call with a rejected result already loses a trailing sub-note;
- a new request part is a slot kind or a rule when it can be one, which adds no overload;
- raising the ceiling (slot arity 4, a third family, or anything else that adds overloads to existing names) is a decision of its own, taken when a concrete shape requires it. That decision compares adding the overloads with a carrier slot kind that holds several parts: application code for the shape, conversion and error order, diagnostics, and build time measured as in this record's pull request. It states the overload count before and after;
- a method name beyond the five starts from a copy of the `get` or the `post` set (M3-020's pattern); a rule of its own (a method-specific constraint in `_rule`, which adds no overload) is decided with that method, and its decision states the new count.

**Rejected.**
- No budget (M3-014's and M3-022's accepted costs as the only guide): slot arity 4 adds ten overloads across the five names in one item, and nothing makes that a deliberate choice.
- Ruling out slot arity 4 and a third family now: neither the carrier alternative nor the requirement it would serve exists yet, so the comparison cannot be made.
- One registration over every handler arity: Mojo 1.1.0 has no variadic function types (`state_fail/variadic_handler_type.mojo`).
- One overload per method name forwarding a generic handler `H` to a shared overload set: `H` does not convert to a function type whose parameters must be inferred (`registration_fail/generic_handler_cannot_forward.mojo`).
- Method names as comptime members binding the method of one shared registration method (`comptime get = Self.route["GET", ...]`): the member is not a method, so `app.get[path](handler)` does not compile (`registration_fail/method_alias_drops_self.mojo`); only `App.get[path](app, handler)` does, a spelling change for every route.
- A generic `app.route[method, path]` beside or instead of the names: rejected by M3-014 (C4b) and M3-020 (C) for its second spelling; nothing here changes that.
- Generating the overload sets with a script: each body is three calls into shared functions and the docstrings differ per method, so a generator adds a build step and a second source of truth while the compiler and the reader see the same forty overloads.

These are the two forms of one shared set that were tested; sharing more of the bodies behind unchanged per-method signatures was not, and stays open as a refactor.

**Revisit when:**
- `state_fail/variadic_handler_type.mojo`, `registration_fail/generic_handler_cannot_forward.mojo` or `registration_fail/method_alias_drops_self.mojo` compiles: re-measure the shared mechanism it allows, against the diagnostics the fixtures under `tests/` pin;
- Mojo reflects function parameters (types or names): one generic entry point over the handler's own type may become expressible;
- `header_access_fail/eleven_candidates_drop_a_note.mojo` changes its text: the ten-note cap that weighs on the ceiling moved;
- a needed shape cannot be a slot kind or a rule within slot arity 3, or a second injected kind is proposed: decide the ceiling as above;
- after a Mojo upgrade, repeating the measurement shows the declared overload set or the slot arity costing build time distinguishable from noise.

**Next production slice:** none (a standing constraint, `docs/DEVELOPMENT.md` section 2). Its owner is `docs/ARCHITECTURE.md`, "Registration surface", which this record's pull request writes, with the two new fixtures in its revisit index.
