"""Flare loopback probe for the JSON decision (M3-008 evidence).

Runs only in the `flare` pixi environment (scripts/check_flare.sh). A
production `App` with the decision spike's `Json[T]` routes
(tests/json_spike.mojo, built with `-I tests`) is served through
`MuntinHandler` in a forked child, as in
adapters/flare/test_localhost_roundtrip.mojo. It measures what the Flare
seam does to the fields and bytes the JSON contract relies on:

- a request `Content-Type` (including `; charset=utf-8`) reaches `Request`
  unchanged, so the selected request rule can be decided in Muntin;
- `Json[T]`'s response `Content-Type: application/json` reaches the client
  unchanged, after the adapter's outbound rule, beside Flare's own
  `Content-Length`;
- a JSON body with UTF-8 and escapes round-trips byte for byte and equals
  `App.handle`;
- Flare's `HttpClient.post(url, String)` sets `Content-Type:
  application/json` itself (so a test meaning "no Content-Type" must build
  the request);
- invalid UTF-8 in a body reaches Muntin already replaced by U+FFFD (the
  M2-016 fact), so the codec never sees the invalid bytes and a JSON string
  holding them parses.
"""

from std.ffi import c_uint, external_call
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from flare.http import HttpClient, HttpServer
from flare.http import Request as FlareRequest
from flare.net import SocketAddr
from flare.utils import SIGKILL, exit, fork, kill, waitpid
from muntin import App, Headers, Request, Response
from muntin_flare import MuntinHandler
from json_spike import FromJson, Json, JsonValue, JsonWriter, ToJson

comptime TIMEOUT_MS = 5_000
comptime CHILD_LIFETIME_S = 30


@fieldwise_init
struct Greeting(FromJson, ToJson):
    var name: String

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        return Self(value["name"].string())

    def write_json(self, mut out: JsonWriter) raises:
        out.begin_object()
        out.name("hello")
        out.string(self.name)
        out.end_object()


def greet(var body: Json[Greeting]) -> Json[Greeting]:
    return Json(body^.take())


def content_type(var request: Request) -> Response:
    var all = request.headers.get_all("content-type")
    var out = String(len(all))
    for v in all:
        out += "|" + v
    return Response.text(out)


def json_app() -> App:
    var app = App()
    app.post["/greet"](greet)
    app.post["/ct"](content_type)
    return app^


@fieldwise_init
struct _Child(Copyable):
    var pid: Int
    var port: Int


def _serve_in_child(var app: App) raises -> _Child:
    var server = HttpServer.bind(SocketAddr.localhost(0))
    var port = Int(server.local_addr().port)
    var pid = fork()
    if pid < 0:
        raise Error("fork() failed")
    if pid == 0:
        _ = external_call["alarm", c_uint](c_uint(CHILD_LIFETIME_S))
        try:
            server.serve(MuntinHandler(app^))
        except e:
            print("server child: serve failed:", e)
        exit(1)
    return _Child(pid, port)


def _client() raises -> HttpClient:
    return HttpClient(timeout_ms=TIMEOUT_MS).with_read_timeout(TIMEOUT_MS)


def _request(url: String, body: String, ct: String) raises -> FlareRequest:
    var req = FlareRequest("POST", url, List(body.as_bytes()))
    if ct.byte_length() > 0:
        req.headers.append("Content-Type", ct)
    return req^


def test_json_fields_and_bytes_over_loopback() raises:
    var child = _serve_in_child(json_app())
    var base = String("http://127.0.0.1:", child.port)
    try:
        var client = _client()
        var app = json_app()
        # The request Content-Type reaches Request unchanged.
        var ct = "application/json; charset=utf-8"
        assert_equal(
            client.send(_request(base + "/ct", "-", ct)).text(), "1|" + ct
        )
        assert_equal(client.send(_request(base + "/ct", "-", "")).text(), "0")
        # Flare's String post sets application/json itself.
        assert_equal(
            client.post(base + "/ct", "x").text(), "1|application/json"
        )
        # JSON round trip: bytes, status and Content-Type equal App.handle.
        var body = '{"name":"Ad\\u00e9 \\"\\ud83d\\ude00\\" é"}'
        var resp = client.send(_request(base + "/greet", body, ct))
        var h = Headers()
        h.add("Content-Type", ct)
        var local = app.handle(Request("POST", "/greet", body, h^))
        assert_equal(resp.status, 200)
        assert_equal(resp.text(), local.body)
        assert_equal(resp.text(), '{"hello":"Adé \\"😀\\" é"}')
        assert_equal(resp.headers.get("content-type"), "application/json")
        assert_equal(
            local.headers.get("content-type").value(), "application/json"
        )
        assert_true(resp.headers.contains("content-length"))
        # Malformed JSON: 400 on both paths.
        var bad = client.send(_request(base + "/greet", '{"name":', ct))
        assert_equal(bad.status, 400)
        assert_equal(
            bad.status, app.handle(Request("POST", "/greet", '{"name":')).status
        )
        assert_false(bad.headers.contains("content-type"))
        # Invalid UTF-8 arrives replaced, so the JSON string parses.
        var raw = List[UInt8]('{"name":"'.as_bytes())
        raw.append(0xFF)
        for b in '"}'.as_bytes():
            raw.append(b)
        var req = FlareRequest("POST", base + "/greet", raw^)
        req.headers.append("Content-Type", "application/json")
        var lossy = client.send(req)
        assert_equal(lossy.status, 200)
        assert_equal(lossy.text(), '{"hello":"�"}')
    finally:
        _ = kill(child.pid, SIGKILL)
        waitpid(child.pid)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
