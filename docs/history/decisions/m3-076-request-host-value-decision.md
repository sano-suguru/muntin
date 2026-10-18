# Request Host value decision (M3-076)

> **Current.** Now described in [headers reference, "Through the Flare adapter"](../../reference/headers.md#through-the-flare-adapter) and [ARCHITECTURE, "Flare adapter"](../../ARCHITECTURE.md#flare-adapter).

Status: **decision and production** (M3-076, pull request #174; `src/muntin` unchanged). It changes part of [M3-073](m3-073-request-host-decision.md) and, like it, reopens M2 under [M2-016](m2-016-m2-closure.md). The RFC text, Flare's source and the observations are in the pull request.

**Question and what settles it.** RFC 9112 section 3.2 answers 400 to "a Host header field with an invalid field value" in any request; M3-073 checks presence only, and Flare v0.12.0 admits any value. What grammar per protocol, when is an empty value allowed, and how must `host` and `:authority` agree over HTTP/2? Settled by RFC 9110 section 7.2, RFC 9112 sections 3.2 and 3.3, RFC 9113 section 8.3.1, and what Flare hands the adapter (`compat/flare/headers/flare_header_probe.mojo`).

**Choice: on every version, a `Host` value that is not `uri-host [ ":" port ]` is the adapter's 400 (M3-073's, under the `HEAD` rule), as is an empty one over HTTP/2.** The grammar is RFC 9110's with RFC 3986's `host` (a bracketed IPv6 or IPvFuture literal, or a `reg-name`, possibly empty) and `port` (any digits); an `:authority` without userinfo, which RFC 9113 requires, is the same production.
- Empty: kept over HTTP/1, where RFC 9112 has a client send it for a target without an authority. Over HTTP/2 a client omits `:authority` instead, and Flare skips its comparison for an empty one and drops the `host` beside it, so serving it would hide a disagreeing `host`.
- Agreement: Flare resets a stream whose `host` differs byte for byte from a non-empty `:authority`, a case-only difference included (RFC 9113 normalizes first, a SHOULD; a client MUST NOT send one), and hands over `:authority` alone. The adapter adds nothing.

**Rejected.**
- Check in `App.handle`: in-memory requests have no `Host` (M3-073).
- Refuse an empty value over HTTP/1: RFC 9112 defines it.
- Bound the port, or require a host before it: not in the grammar.
- Zone identifiers (RFC 6874): not in RFC 3986, which RFC 9110 cites.
- Compare `host` with `:authority` normalized: Flare drops `host` first.

**Revisit when:**
- the Flare pin moves and a probe `Host` case changes (Flare checks the value, normalizes, or keeps a dropped `host`);
- a backend hands over both `:authority` and `host`;
- an application needs to route on the host.

**Next production slice (M3-076, in this item).**
- Code: `adapters/flare/muntin_flare.mojo`: `_refuses_host` and `_is_host_value` replace `_lacks_host`.
- Tests: `adapters/flare/test_muntin_flare.mojo`, valid and invalid values over HTTP/1.0, 1.1, 1.9 and 2, with `HEAD`; the M3-073 case of `adapters/flare/test_localhost_roundtrip.mojo` extended over HTTP/1, h2c and an upgrade; the probe's `Host` cases.
- Docs: headers reference, `docs/ARCHITECTURE.md`, `docs/SPEC.md`, M2's reopen list.
