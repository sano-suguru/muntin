# Deferrals

A decision to build nothing now, with no decision record (`docs/DEVELOPMENT.md` section 2), binds later items through its revisit condition, so that condition is kept here, versioned with the code it constrains. Each entry is the choice, why, the revisit condition and its pull request; the discussion stays in the candidate's GitHub issue, which links the entry. The text of each entry below is as `docs/SPEC.md`, "Remaining candidates", stated it before the candidates moved to issues.

## Linear request header conversion

Issue [#140](https://github.com/sano-suguru/muntin/issues/140); measured in [pull request #110](https://github.com/sano-suguru/muntin/pull/110).

The adapter's check of the fields it rebuilds costs fields × distinct names comparisons inside Flare, bounded since M3-067 by `Server.bind`'s `max_header_fields` (100 unless set; [M3-066](architecture-decisions.md#request-header-conversion-decision-m3-066)). A conversion through an ordered field accessor on Flare's `HeaderMap`, which would make raising the limit cheap, waits on Flare (pull request #119 drafts the proposal) and then a pin change.

## Spreading kept-open connections over workers (M3-069)

Issue [#155](https://github.com/sano-suguru/muntin/issues/155); [pull request #137](https://github.com/sano-suguru/muntin/pull/137), measured by [pull request #109](https://github.com/sano-suguru/muntin/pull/109).

[M3-068](architecture-decisions.md#worker-connection-spread-decision-m3-068) keeps the shared listener. M3-069 adopts none of its candidates, because re-registering the listener after each accept batch, Flare's `EPOLLEXCLUSIVE` fix (29550b6) alone and a `SO_REUSEPORT` listener per worker each raise how often a connection opened as a slow request is sent waits for it over the pin's, which M3-068's rules do not allow, and accept budgets changed nothing measured. Revisit when Flare rebalances its shared listener, or before the pin moves to a release carrying 29550b6, which that comparison measured as a regression (every connection opened in turn on one worker).

## Connection cap for `Server`

Issue [#156](https://github.com/sano-suguru/muntin/issues/156); [pull request #131](https://github.com/sano-suguru/muntin/pull/131).

A connection cap for `Server` (`max_connections`, counted for the whole `Server`) is deferred by pull request #131, which built it on Flare v0.12.0's per-reactor `max_connections` and measured that while a connection waits over the cap each full reactor spins a CPU core (its level-triggered poll keeps returning the readable listener), so the cap, a load control, would exhaust CPU in normal use; fixed per-worker shares also leave a free slot on one worker unusable by another. Revisit when Flare (a pin change, decided separately) stops polling the listener at its cap and accepts again once a slot frees, shown with no spin while connections wait, waiting connections accepted on several workers on Linux and macOS, and the graceful stop and TLS handshakes unchanged; fixed shares against a shared counter are compared then.
