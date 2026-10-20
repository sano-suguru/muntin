# Deferrals

A decision to build nothing now, with no decision record (`docs/DEVELOPMENT.md` section 2), binds later items through its revisit condition, so that condition is kept here, versioned with the code it constrains. So are conditions a withdrawn design sets on its successor. Each entry is the choice, why, the revisit condition and its pull request; the discussion stays in the candidate's GitHub issue, which links the entry. The entries written before the candidates moved to issues keep the text `docs/SPEC.md`, "Remaining candidates", gave them.

## Linear request header conversion

Issue [#140](https://github.com/sano-suguru/muntin/issues/140); measured in [pull request #110](https://github.com/sano-suguru/muntin/pull/110).

The adapter's check of the fields it rebuilds costs fields × distinct names comparisons inside Flare, bounded since M3-067 by `Server.bind`'s `max_header_fields` (100 unless set; [M3-066](decisions/m3-066-request-header-conversion-decision.md)). A conversion through an ordered field accessor on Flare's `HeaderMap`, which would make raising the limit cheap, waits on Flare (pull request #119 drafts the proposal) and then a pin change.

## Spreading kept-open connections over workers (M3-069)

Issue [#155](https://github.com/sano-suguru/muntin/issues/155); [pull request #137](https://github.com/sano-suguru/muntin/pull/137), measured by [pull request #109](https://github.com/sano-suguru/muntin/pull/109).

[M3-068](decisions/m3-068-worker-connection-spread-decision.md) keeps the shared listener. M3-069 adopts none of its candidates, because re-registering the listener after each accept batch, Flare's `EPOLLEXCLUSIVE` fix (29550b6) alone and a `SO_REUSEPORT` listener per worker each raise how often a connection opened as a slow request is sent waits for it over the pin's, which M3-068's rules do not allow, and accept budgets changed nothing measured. Revisit when Flare rebalances its shared listener, or before the pin moves to a release carrying 29550b6, which that comparison measured as a regression (every connection opened in turn on one worker).

## Connection cap for `Server`

Issue [#156](https://github.com/sano-suguru/muntin/issues/156); [pull request #131](https://github.com/sano-suguru/muntin/pull/131).

A connection cap for `Server` (`max_connections`, counted for the whole `Server`) is deferred by pull request #131, which built it on Flare v0.12.0's per-reactor `max_connections` and measured that while a connection waits over the cap each full reactor spins a CPU core (its level-triggered poll keeps returning the readable listener), so the cap, a load control, would exhaust CPU in normal use; fixed per-worker shares also leave a free slot on one worker unusable by another. Revisit when Flare (a pin change, decided separately) stops polling the listener at its cap and accepts again once a slot frees, shown with no spin while connections wait, waiting connections accepted on several workers on Linux and macOS, and the graceful stop and TLS handshakes unchanged; fixed shares against a shared counter are compared then.

## Closing `State`'s `AnyOrigin` hole

Issue [#173](https://github.com/sano-suguru/muntin/issues/173); [pull request #175](https://github.com/sano-suguru/muntin/pull/175).

[M3-074](decisions/m3-074-state-borrowing-decision.md)'s check reads `S`'s name, and a pointer built with `AnyOrigin` behind a trait's associated type stays out of it (`tests/state_known_gaps/state_any_origin_associated_type.mojo`); the same pointer registers inside an `Optional`, a `List` or a `Tuple` field of the application's own struct (`state_any_origin_in_optional.mojo`, `_in_list.mojo`, `_in_pack_field.mojo`), and each reads freed memory under `scripts/run_origin_gaps.sh`. No check is added, because none found on Mojo 1.1.0 refuses these and still admits owned states: walking the field types reaches the pointer, but it prints `{}` like the untracked pointers inside `List`, `String` and `ArcPointer`, and none of the ways tried in generic code tells `AnyOrigin` from those (`tests/state_fail/state_any_origin_*.mojo`: `Origin.equals` only in a `where` clause, no overload selected by one, a type comparison that ignores origins); packs stay closed to reflection, so the `Optional` and `Tuple` forms would pass even then. Refusing application-defined generic structs and packs in fields stops the four reproductions, but refuses owned states such as `Cache[Item]` and M3-074's own migration (`struct Pair: var value: Tuple[...]`), without showing that nothing else gets through. Revisit when Mojo refuses a field whose type exposes `AnyOrigin` through an associated type (the four known gaps stop building or reporting: remove them and this entry), or when a `state_any_origin_*` fail fixture builds and generic code can also reach a pointer's pointee and a pack's elements: then weigh a check of the field types that refuses `AnyOrigin`.

## Candidates after the comparison by new authors

The owner's review of pull request #172. Entry 5 of `docs/SPEC.md`, "Remaining candidates" ([#171](https://github.com/sano-suguru/muntin/issues/171)), measures whether Muntin reduces what an author must remember. Recording its results alone would let a poor result lead straight to the next feature, so no entry after it starts until the owner, from those results, decides whether to resume the candidates, reorder them or narrow Muntin's scope. Correctness and safety fixes are not held. Entry 5 starts once entries 2 to 4 have each shipped or been decided against: why a feature could not be built soundly is part of what it evaluates, so a sound deferral does not hold it back. Revisit when the owner has decided: the decision replaces this entry and the link to it in `docs/SPEC.md`.
