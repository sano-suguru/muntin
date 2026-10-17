# Real localhost round trip (M1-003)

> **Current.** Now described in [ARCHITECTURE, "Architecture tests"](../../ARCHITECTURE.md#architecture-tests), [ARCHITECTURE, "Current limits"](../../ARCHITECTURE.md#current-limits) and [DEVELOPMENT, "3. Verify with the strongest available oracle"](../../DEVELOPMENT.md#3-verify-with-the-strongest-available-oracle).
> Changed in part since:
> - [M3-032](m3-032-serving-entrypoint-decision.md): the loopback fixture now serves through `Server.bind`/`server.serve(app)` instead of `HttpServer.serve(MuntinHandler)`.

```text
HttpClient --TCP 127.0.0.1:<ephemeral>--> HttpServer.serve -> MuntinHandler.serve
  -> App.handle -> registered route -> Response -> Flare response -> wire
```

`adapters/flare/test_localhost_roundtrip.mojo` is the proof. Its server lifecycle is test fixture code, not a Muntin API: `HttpServer.serve` owns its thread, so the test binds in the parent (`bind` already listens, so readiness is `bind` returning), forks a child that serves `MuntinHandler`, drives Flare's `HttpClient` with connect/read timeouts, and SIGKILLs and reaps the child in `finally`; the child also arms a 30-second `alarm(2)`. No `app.run()`, runtime, or shutdown API was added to Muntin, and the adapter itself is unchanged.
