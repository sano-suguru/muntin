# Headers in production (M3-005): `muntin.Headers`, `Request.headers` and
# `Response.headers`, and raw handlers reading and writing fields through
# `App.handle`. Decision: docs/history/architecture-decisions.md, "Headers
# decision (M3-002)". Must-not-compile counterparts: tests/headers_api_fail.

from std.testing import assert_equal, assert_false, assert_raises
from std.testing import assert_true, TestSuite

from muntin import App, Headers, Request, Response, ToResponse
from muntin.testing import TestClient


def _fields(h: Headers) -> String:
    var out = String()
    for i in range(len(h)):
        out += h.name(i) + "=" + h.value(i) + ";"
    return out^


# Headers semantics.


def test_order_casing_and_repeats_are_kept() raises:
    var h = Headers()
    h.add("X-B", "2")
    h.add("Content-Type", "text/plain")
    h.add("x-b", "3")
    h.add("Set-Cookie", "a=1; Expires=Wed, 21 Oct 2026 07:28:00 GMT")
    h.add("Set-Cookie", "b=2")
    assert_equal(len(h), 5)
    assert_equal(
        _fields(h),
        (
            "X-B=2;Content-Type=text/plain;x-b=3;Set-Cookie=a=1; Expires=Wed,"
            " 21 Oct 2026 07:28:00 GMT;Set-Cookie=b=2;"
        ),
    )


def test_lookup_is_ascii_case_insensitive() raises:
    var h = Headers()
    h.add("X-Signature", "abc")
    h.add("x-signature", "def")
    assert_equal(h.get("x-SIGNATURE").value(), "abc")
    var all = h.get_all("X-SIGNATURE")
    assert_equal(len(all), 2)
    assert_equal(all[1], "def")
    assert_false(Bool(h.get("X-Missing")))
    assert_equal(len(h.get_all("X-Missing")), 0)


def test_empty_value_is_present() raises:
    var h = Headers()
    h.add("X-Empty", "")
    assert_true(Bool(h.get("x-empty")))
    assert_equal(h.get("x-empty").value(), "")


def test_set_replaces_every_field_with_that_name() raises:
    var h = Headers()
    h.add("Vary", "a")
    h.add("X-Keep", "k")
    h.add("vary", "b")
    h.set("VARY", "c")
    assert_equal(_fields(h), "X-Keep=k;VARY=c;")


def test_invalid_names_and_values_are_rejected() raises:
    var h = Headers()
    with assert_raises(contains="invalid header name"):
        h.add("", "v")
    with assert_raises(contains="invalid header name"):
        h.add("X Space", "v")
    with assert_raises(contains="invalid header name"):
        h.add("X:Colon", "v")
    with assert_raises(contains="invalid header value"):
        h.add("X-Inject", "a\r\nSet-Cookie: evil=1")
    with assert_raises(contains="invalid header value"):
        h.add("X-Lf", "a\nb")
    with assert_raises(contains="invalid header value"):
        h.add("X-Nul", String("a") + chr(0) + "b")
    with assert_raises(contains="invalid header value"):
        h.set("X-Del", String("a") + chr(127))
    with assert_raises(contains="invalid header value"):
        h.add("X-Lead", " a")
    with assert_raises(contains="invalid header value"):
        h.add("X-Trail", "a\t")
    assert_equal(len(h), 0)
    h.add("X-Ok", 'a\tb: "c" é')
    assert_equal(h.get("x-ok").value(), 'a\tb: "c" é')


def test_headers_copy_explicitly_and_independently() raises:
    var a = Headers()
    a.add("X-A", "1")
    var b = a.copy()
    b.add("X-B", "2")
    assert_equal(len(a), 1)
    assert_equal(len(b), 2)


def test_request_and_response_defaults_add_nothing() raises:
    var req = Request("GET", "/x?y=1", "body")
    assert_equal(len(req.headers), 0)
    assert_equal(req.query, "y=1")
    assert_equal(len(Response.text("hi").headers), 0)
    assert_equal(len(Response(204, "").headers), 0)
    var h = Headers()
    h.add("X-A", "1")
    var with_headers = Request("POST", "/x", "b", h^)
    assert_equal(with_headers.headers.get("x-a").value(), "1")


# Raw handlers through App.handle.


def webhook(req: Request) raises -> Response:
    var sig = req.headers.get("x-signature")
    if not sig:
        return Response.text("unsigned", status=401)
    var resp = Response.text(
        sig.value() + " " + String(len(req.headers.get_all("x-a"))),
        status=202,
    )
    resp.headers.add("X-Request-Id", "42")
    resp.headers.add("Set-Cookie", "a=1")
    resp.headers.add("Set-Cookie", "b=2")
    resp.headers.add("X-Empty", "")
    return resp^


def echo_fields(var req: Request) raises -> Response:
    var resp = Response.text(req.method + " " + req.path + "?" + req.query)
    for i in range(len(req.headers)):
        resp.headers.add(req.headers.name(i), req.headers.value(i))
    return resp^


def inject(req: Request) raises -> Response:
    var resp = Response.text("never")
    resp.headers.add("X-Bad", "a\r\nSet-Cookie: evil=1")
    return resp^


def hello() -> String:
    return "hello"


def typed_get(id: Int) -> String:
    return "typed " + String(id)


@fieldwise_init
struct Created(Movable, ToResponse):
    var id: Int

    def to_response(var self) -> Response:
        var resp = Response.text(String(self.id), status=201)
        # `add` raises and `to_response` must not.
        try:
            resp.headers.add("Location", "/items/" + String(self.id))
        except:
            pass
        return resp^


def create() -> Created:
    return Created(7)


def test_raw_handler_reads_and_writes_headers() raises:
    var app = App()
    app.post["/hook"](webhook)
    var h = Headers()
    h.add("X-SIGNATURE", "sha256=abc")
    h.add("X-A", "1")
    h.add("x-a", "2")
    var got = app.handle(Request("POST", "/hook", "data", h^))
    assert_equal(got.status, 202)
    assert_equal(got.text(), "sha256=abc 2")
    assert_equal(
        _fields(got.headers),
        "X-Request-Id=42;Set-Cookie=a=1;Set-Cookie=b=2;X-Empty=;",
    )
    assert_equal(app.handle(Request("POST", "/hook", "data")).status, 401)


def test_raw_transport_keeps_every_field() raises:
    # Order across names, casing, repeats, empty values, `:` and HTAB in a
    # value, and no fields at all, through App.handle's raw strings.
    var app = App()
    app.get["/echo"](echo_fields)
    var h = Headers()
    h.add("X-B", "2")
    h.add("Content-Type", "text/plain; charset=utf-8")
    h.add("x-b", "")
    h.add("X-Odd", "a:b\tc")
    var got = app.handle(Request("GET", "/echo?k=v", "", h^))
    assert_equal(got.text(), "GET /echo?k=v")
    assert_equal(
        _fields(got.headers),
        "X-B=2;Content-Type=text/plain; charset=utf-8;x-b=;X-Odd=a:b\tc;",
    )
    assert_equal(len(app.handle(Request("GET", "/echo")).headers), 0)


def test_typed_routes_and_string_results_set_no_headers() raises:
    var app = App()
    app.get["/hello"](hello)
    app.get["/items/{id}"](typed_get)
    var h = Headers()
    h.add("X-A", "1")
    var typed = app.handle(Request("GET", "/items/3", "", h^))
    assert_equal(typed.text(), "typed 3")
    assert_equal(len(typed.headers), 0)
    var client = TestClient(app)
    var got = client.get("/hello")
    assert_equal(got.text(), "hello")
    assert_equal(len(got.headers), 0)
    assert_equal(len(client.get("/missing").headers), 0)
    assert_equal(len(client.get("/items/x").headers), 0)


def test_typed_result_sets_headers_through_response() raises:
    var app = App()
    app.get["/items"](create)
    var got = TestClient(app).get("/items")
    assert_equal(got.status, 201)
    assert_equal(got.headers.get("location").value(), "/items/7")


def test_invalid_header_is_a_handler_error() raises:
    var app = App()
    app.get["/inject"](inject)
    var got = TestClient(app).get("/inject")
    assert_equal(got.status, 500)
    assert_equal(got.text(), "Internal Server Error")
    assert_equal(len(got.headers), 0)


# DX section 9's headers example, registered as `dx_webhook`.


def dx_webhook(req: Request) raises -> Response:
    var signature = req.headers.get("x-signature")  # Optional[String]
    if not signature or signature.value() != "sha256=valid":
        return Response.text("unsigned", status=401)
    var resp = Response.text("ok")
    resp.headers.add("X-Request-Id", "42")  # raises if invalid
    return resp^


def test_dx_section_9_headers_example() raises:
    var app = App()
    app.post["/webhook"](dx_webhook)
    var h = Headers()
    h.add("X-Signature", "sha256=valid")
    var ok = app.handle(Request("POST", "/webhook", "", h^))
    assert_equal(ok.status, 200)
    assert_equal(ok.text(), "ok")
    assert_equal(ok.headers.get("x-request-id").value(), "42")
    var unsigned = app.handle(Request("POST", "/webhook"))
    assert_equal(unsigned.status, 401)
    assert_equal(unsigned.text(), "unsigned")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
