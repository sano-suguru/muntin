# Request header conversion decision (M3-066)

> **Current.** Now described in [serving reference, "Request header field limit"](../../reference/serving.md#request-header-field-limit), [headers reference, "Through the Flare adapter"](../../reference/headers.md#through-the-flare-adapter) and [ARCHITECTURE, "Flare adapter"](../../ARCHITECTURE.md#flare-adapter).
> Changed in part since:
> - [M3-073](m3-073-request-host-decision.md): a request without Host is now answered 400 before the 431 check.
> Its pointers into documents that were split or renamed since (`docs/DX.md`, old `docs/ARCHITECTURE.md` headings) are mapped in [the list of records](../architecture-decisions.md#documents-older-records-cite).

Status: **decision** (M3-066, pull request #119, which holds the measurements, the Flare reading, the other servers' limits, the reviews and the drafted proposal to Flare). This item changes no adapter code: until M3-067 merges, the current conversion's unbounded cost stays in every `Server`.

**Question and what settles it.** The Flare adapter rebuilds a request's fields from `HeaderMap.encode_to`'s text and checks the parse with `get_all` once per distinct name ([M3-002](m3-002-headers-decision.md), since pull request #110), and each by-name lookup of Flare v0.12.0 scans every field, so a request costs fields × distinct names comparisons; Flare's 8 KB header limit bounds that only loosely (2,600 distinct names hold a worker about 24 to 30 ms over HTTP/1.1). Should the adapter limit the number of fields, convert them another way without Flare's private fields, or both? Settled by every public `HeaderMap` method (read in Flare v0.12.0), a prototype of the other conversion tested against the adapter's and measured beside it in process and over loopback (`scripts/bench_headers.sh`), and the field limits of other HTTP servers (their documentation).

**Choice: keep the adapter's conversion, which uses public `HeaderMap` methods only, and answer a request with more than `max_header_fields` fields (100 unless set) 431 before converting it.**
- The limit bounds the square. The largest request it admits by default, `Host` and 99 distinct names, takes 0.34 ms over loopback (median; Flare alone 0.10 ms), its conversion about 0.12 ms in process; at 200 such requests a second, p50, p95 and p99 are 0.98, 1.35 and 2.3 ms (Flare alone 0.78, 1.28 and 2.3). A browser's 12 fields cost about 0.1 ms, as Flare alone. Above the limit nothing is converted.
- The limit also bounds the cost of each operation that walks the fields after Flare (`Headers.get` and `get_all` scan every field), though not how many such operations the application's code makes. It does not bound Flare's own parse and buffers, which come first (Flare's header byte limits do). It counts the fields Flare hands the adapter, `Host` included: over HTTP/1.1 as received, over HTTP/2 with `:authority` as `Host` and the `cookie` fields joined into one. 100 is Tomcat's, Apache's and hyper's default; a browser sends about 12 to 20.
- Raising the limit brings the square back, and the setting says so: 256 fields of distinct names cost 0.97 ms a request over loopback, 1,000 about 8 ms in process.
- The conversion hands the handler every field as sent, name, value, order and repeats, over HTTP/1.1 and h2c (`adapters/flare/test_localhost_roundtrip.mojo`; Flare's HTTP/2 `Host` and `cookie` handling aside, `docs/DX.md` section 9).
- Upstream, an ordered accessor on `HeaderMap` (by index or an iterator) would make the conversion linear with no check; pull request #119 drafts the proposal. If Flare declines, nothing here changes.

**Rejected.**
- Rebuilding the fields from the four pieces per field `HeaderMap.write_to` hands a `Writer`, with the same limit (this record's earlier draft; prototype `bench/headers/pieces_rebuild.mojo`): saves about 0.2 ms on the worst request the default admits (0.11 ms over loopback; at 200 a second p50 0.85 ms, with no p95 or p99 gain in this measurement, which includes the client's own start-up delay), for reliance on a split Flare does not document, which tests and a start-up check catch only for the cases they cover.
- A limit of 256: its worst request costs 0.97 ms, about three times 100's, and no client Muntin serves is known to need it.
- Either conversion with no limit: leaves per-field costs, the rebuild's included, to application code nobody measured.
- Reading `HeaderMap._keys` and `._values`: undocumented, and breaks M3-002's rule that the adapter never reads them.
- `encode_to` with `get_all` only for lines with two colons: a client controls that count, so the worst case stays the square.
- Dropping the check of the parse: trusts Flare never to deliver a name with `:` (M3-002's forged `x-user:admin`), which Flare does not document.
- Waiting for Flare's accessor: the unbounded cost stays until a release and a pin change Muntin does not decide.

**Revisit when:**
- Flare publishes an ordered accessor on `HeaderMap`: convert through it and drop the check (a pin change, with the owner's approval);
- a client Muntin should serve sends more than 100 fields, or applications raise the limit enough for the square to matter: the rebuild is a candidate again (`bench/headers/write_to_pieces.mojo` says whether the pinned Flare still splits fields as it needs);
- M3-067's measurements contradict the numbers above, or Flare's header byte limits change: re-measure with `scripts/bench_headers.sh` and reopen this choice.

**Next production slice (M3-067).**
- `adapters/flare/muntin_flare.mojo`: `_answer` answers 431 `Request Header Fields Too Large` when `request.headers.len()` exceeds the `Server`'s limit, before `to_muntin_headers`, without calling `App.handle`. `Server.bind(..., max_header_fields: Int = 100)`, 1 to 65,535, checked after `idle_timeout_ms` (`max_header_fields out of range: <n>`). The conversion is unchanged.
- Tests, `adapters/flare/test_muntin_flare.mojo`: 100 fields converted and 101 answered 431 with no `App.handle`; with the limit raised, 4,000 fields converted exactly. Loopback, HTTP/1.1 and h2c (`test_localhost_roundtrip.mojo`), counted as Flare hands the fields over: 100 served, 101 answered 431 and the server keeps serving; over h2c, 101 `cookie` fields served as one. `test_server.mojo`: the setting's range and its order among the settings.
- Measure with `scripts/bench_headers.sh`, base against slice: 101 fields and the largest blocks answered 431 at about Flare alone's cost; at most 100 fields unchanged.
- Docs: `docs/ARCHITECTURE.md` (the request header rule and 431); `docs/DX.md` section 1 (`max_header_fields`, 431, the cost of raising it); `docs/SPEC.md` (the candidate).
- Not in the slice: another conversion, Flare's accessor and the pin change.
