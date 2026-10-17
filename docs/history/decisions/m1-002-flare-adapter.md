# Flare adapter (M1-002)

> **Current.** Now described in [ARCHITECTURE, "Flare adapter"](../../ARCHITECTURE.md#flare-adapter), [ARCHITECTURE, "Adapter translation policy"](../../ARCHITECTURE.md#adapter-translation-policy) and [serving reference](../../reference/serving.md#serving-muntin_flareserver).
> Changed in part since:
> - [M3-005](m3-005-headers-in-production.md): request header fields are no longer dropped: the adapter rebuilds and verifies them (400 on failure) and carries response fields.
> - [M3-032](m3-032-serving-entrypoint-decision.md): serving goes through the adapter's `Server`, which borrows the App (`_BorrowedHandler`); MuntinHandler remains for tests and probes.
> - [M3-038](m3-038-request-body-bytes-decision.md): the lossy UTF-8 body decoding was ended (non-UTF-8 body refused with 400; that refusal later replaced by M3-040).
> - [M3-039](m3-039-request-target-and-method-bytes-decision.md): method and target are copied as strict UTF-8; otherwise the adapter's 400.
> - [M3-040](m3-040-binary-request-and-response-bodies-decision.md): body bytes now pass unchanged both ways as List[UInt8].

```text
flare.http.Request -> to_muntin_request -> muntin.Request
  -> App.handle -> muntin.Response -> to_flare_response -> flare.http.Response
```

`MuntinHandler` owns an `App` and implements Flare's `Handler` trait, so its `serve(Request) -> Response` is the call Flare's server makes; it does no routing of its own. Conversion is by copy: method and the request target (`url`, path plus query, undecoded) verbatim into `Request(method, target, body)`, which splits it in core (M2-002), so routing and query extraction match the in-memory backend; body bytes decoded into a `String` as lossy UTF-8; headers, version and peer dropped. The response copies status and body bytes, leaves the reason unset (Flare's default applies), and sets no headers. The policy is listed in the module docstring. `adapters/flare/test_muntin_flare.mojo` tests it without a socket; `check_flare.sh` builds it with `--Werror`, runs it, and checks that the adapter does not build in the default environment. `adapters/flare/serve_probe.mojo` type-checks `HttpServer.bind(...).serve(handler^)` with an owned `MuntinHandler` and exits before binding, so the ownership shape is accepted by Flare's single-worker server without opening a socket. CI runs `check_flare.sh` on Ubuntu and macOS from a cold `pixi install --locked -e flare`.
