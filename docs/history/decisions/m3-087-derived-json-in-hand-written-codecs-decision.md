# Derived JSON values inside hand-written codecs decision (M3-087)

> **Current.** Not built yet: its "Next production slice" is M3-088.

Status: **decision** (M3-087, issue [#195](https://github.com/sano-suguru/muntin/issues/195)). Evidence: the pull request. Changes part of M3-082 (below).

**Question and what settles it.** A hand-written `write_json` cannot write a `JsonFields` value (`out.field` takes `ToJson` types), and a hand-written `from_json` has no derived reader to call, so a type that needs one special member (a renamed or checked one, an envelope) writes every nested DTO by hand again: the drift [M3-082](m3-082-derived-json-codecs-decision.md) removed (#167's `tag`). Through what Muntin-owned API does a hand-written codec read and write a derived value, with which kinds, how is a field that cannot be read or written refused, and does a read failure keep its member path ([M3-084](m3-084-request-rejection-report-decision.md))? Settled by Mojo 1.1.0 probes of the overload sets; a scratch copy of production passing `check.sh`, `test.sh` (under AddressSanitizer too) and `check_flare.sh` with a spike through `TestClient`; the refusal measured against the registration rules'; and a fresh-context review.
