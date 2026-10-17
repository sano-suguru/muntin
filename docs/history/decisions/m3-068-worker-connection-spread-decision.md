# Worker connection spread decision (M3-068)

> **Current.** Now described in [serving reference, "Workers"](../../reference/serving.md#workers) and [deferrals, "Spreading kept-open connections over workers (M3-069)"](../deferrals.md#spreading-kept-open-connections-over-workers-m3-069).
> Its pointers into documents that were split or renamed since (`docs/DX.md`, old `docs/ARCHITECTURE.md` headings) are mapped in [the list of records](../architecture-decisions.md#documents-older-records-cite).

Status: **decision** (M3-068, pull request #120): keep the shared listener and Flare v0.12.0's registration; the spread below is a candidate, not chosen. `src/muntin` and the adapter's behavior are unchanged. Measurements and reviews are in the pull request; the Flare patch, probes and scripts are in `bench/hol/spread/`.

**Question and what settles it.** `serve[make](workers=n)`'s workers share one listener, and connections kept open cluster on one worker (`docs/DX.md` section 1, Workers; pull request #109), so how many of a keep-alive pool's or h2c client's connections wait behind a slow handler depends on which worker took them. Can new connections be spread on Linux while [M3-049](m3-049-multi-worker-serving-decision.md)'s guarantee, [M3-045](m3-045-graceful-shutdown-decision.md)'s stop and [M3-060](m3-060-tls-with-workers-decision.md)'s TLS workers hold, without making Flare's other loops worse or the server less available? Settled by Flare v0.12.0 read and traced, Linux's wake-up rules probed outside Flare, candidates measured with `bench/hol`, a registration failure injected, and `scripts/check_flare.sh` run against the candidate. The cause: Flare asks for `EPOLLEXCLUSIVE` with `EPOLLRDHUP`, which Linux refuses (`EINVAL`), and falls back to a plain registration, so every idle worker wakes for each new connection and the first to accept takes it.

**Choice: keep one shared listener and change nothing now.** The leading candidate: in Flare's unified shared-listener loop only (the one Muntin runs), for its primary listener only, register with `EPOLLEXCLUSIVE` and without `EPOLLRDHUP`, and register again after each accept batch; Flare's other shared loops and `extra_fds` keep v0.12.0's registration, because the flag alone makes one idle worker take every connection (16 of 16 in every run). With both, 4/4/4/4 in every run. It is not chosen, because:
- the order is Linux 6.18's implementation (exclusive waiters woken from the head; one not waiting is skipped), not `epoll_ctl(2)`'s contract, measured on one kernel;
- it adds a run-time failure on every accept batch (`EPOLL_CTL_ADD`: memory, the user's watch limit), which today ends the worker and, through `serve`'s policy, the server;
- `register_exclusive` falls back to a plain registration on any failure and does not say so, so a worker can silently mix modes, where Linux delivers to every plain registration;
- Flare's accept loop takes connections until `EAGAIN` with no budget per wake-up, so under sustained arrivals a batch, and that worker's open connections, may wait long (true today; with the candidate, unmeasured);
- it places new connections only: one already on a worker still waits behind that worker's slow handler (8 pooled connections: the slow worker held 2 in every run, against 0 to 7 now), and an h2c connection's streams are not helped at all;
- Flare's maintainers have not seen it.

M3-049's guarantee, split. A contract, tested: a connection opened while one worker is already running a handler is answered by another idle worker. Not a contract, before or after: a connection opened just before a worker starts a slow handler; with the candidate it goes to the one worker woken and waits if a long request reaches that worker first (inferred from the kernel source, not reproduced).

**Kept for comparison in M3-069.** A `SO_REUSEPORT` listener per worker (prototyped): the hash sends about one new connection in n to a held worker, so the contract above becomes chance; any process of the same user can bind the port; balancing is Linux only. An accept budget per wake-up, alone or with the candidate.

**Rejected.**
- Rebinding per-worker listeners in `serve`: resets connections opened between `bind` and `serve`, which `docs/DX.md` section 1 lets a client open.
- eBPF steering (`SO_ATTACH_REUSEPORT_EBPF`): privileges, a BPF program and per-request bookkeeping.
- Fixing the flag in `register_exclusive` for every caller: Flare's other shared loops would concentrate connections.
- Accepting before the batch's other events: the accepted connection then waits on that worker anyway.
- Re-registering through a second descriptor: it keeps the listener open through M3-045's parking.
- Re-registering from the adapter, pinning an unmerged Flare commit, `WorkerHandoffPool`: outside Muntin's reach, unreviewed, or larger.

**Revisit when:**
- Flare's maintainers answer the bug report or a proposal, or a Flare tag changes the registration or the accept loop: the next slice;
- pools stall in use before then: weigh the per-worker listener and an accept budget again;
- a kernel stops spreading, or spread on macOS (no exclusive wake-up) matters.

**Next slice (M3-069): choose how to spread, then adopt it.** Starts when Flare's maintainers have answered. It compares the candidate with the per-worker listener and an accept budget, adopts one only if it passes every rule below, and otherwise records why none was; the pin moves only on a Flare tag or merged commit and the owner's approval. It decides and tests:
- failure: whether a failed registration ends the server, ends only that worker, or is retried while the worker serves its open connections, telling a transient error from a lost listener, against a stop and churn on other threads (`SIGTERM`, connections opened in a loop, a failed re-registration);
- the mode: an exclusive registration that fails says so (no silent fallback), every worker runs one mode, and a kernel without `EPOLLEXCLUSIVE` (before Linux 4.5) keeps v0.12.0's registration;
- the accept budget: today's loop against at most 1, 4, 16 and 64 connections per wake-up, under sustained arrivals, comparing p99 and p99.9 of requests on open keep-alive connections and that a listener left with a backlog is served again; admission (a connection cap) stays its own item (`docs/SPEC.md`, deferred by [pull request #131](https://github.com/sano-suguru/muntin/pull/131), whose full reactors spin on the readable listener);
- measurement against the pin, alternating, with `bench/hol/spread/run_spread.sh` extended (it already fails on a fault the patched server outlives and on any churn attempt not answered in full): spread and a backlog while every worker is held, 20 runs each, the busiest worker's median and maximum no higher than the pin's; steady, churn and keep-alive load, 10 runs, the rate of answered requests at least 90% of the pin's and CPU per answered request and p99 at most 110% (one-sided); errors reported for every load test, a rise over the pin's explained and accepted or the slice stops;
- waiting for the hold, and resets, 1,000 trials each of a connection opened as a slow request is sent and as a stop starts: a rise over the pin's by a one-sided Fisher exact test at 5% stops the slice; it screens and proves no absence (0 against 4 of 1,000 passes), so the slice reports counts, the difference and its 95% confidence interval;
- the same-batch order counts only where a test-only control point makes it happen or a trace shows it; trials that did not reach it claim nothing;
- if adopted: [M3-070](m3-070-backend-coupling-decision.md)'s rule for a new reliance (the spread rests on a wake-up order no kernel document states), the pin (`pixi.toml`, `pixi.lock`, `docs/REFERENCES.md`, `scripts/check_flare.sh`, every name in `adapters/flare/flare_internals.mojo`), the existing workers, stop and TLS workers tests unchanged plus a stop while connections are being opened, and `docs/DX.md` section 1, `docs/ARCHITECTURE.md` (Workers, Graceful shutdown), `docs/SPEC.md`.
