# Spike of M3-089 (prototype only, removed before the decision merges):
# text and JSON body limits. A `FromBody` type's `max_bytes` (1 MiB unless
# it declares another; `Int.MAX` is none) is 413 before the UTF-8 read and
# `from_body`, after the route values; `Json[T, limit=n]` replaces the
# fixed 1 MiB, after the 415 step, bare and carried, and in a raw handler's
# `from_body`; `limit` means nothing on a result. Must-not-build
# counterparts: tests/body_limit_api_fail.

from std.os import getenv, setenv, unsetenv
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from muntin import (
    App,
    State,
    FromBody,
    Headers,
    Json,
    JsonFields,
    Next,
    Request,
    Response,
    WithHeaders,
)
from muntin.testing import TestClient

comptime FROM_BODY_CALLS = "MUNTIN_SPIKE_LIMIT_FROM_BODY_CALLS"
comptime HANDLER_CALLS = "MUNTIN_SPIKE_LIMIT_HANDLER_CALLS"
comptime MIB = 1_048_576


def _count(name: String) -> Int:
    var n = getenv(name)
    try:
        return Int(n) if n else 0
    except:
        return -1


def _bump(name: String):
    _ = setenv(name, String(_count(name) + 1))


def _reset():
    _ = unsetenv(FROM_BODY_CALLS)
    _ = unsetenv(HANDLER_CALLS)


def _filled(n: Int, byte: Int = 0x61) -> List[UInt8]:
    return List[UInt8](length=n, fill=UInt8(byte))


def _json() raises -> Headers:
    var h = Headers()
    h.add("Content-Type", "application/json")
    return h^


def _padded(n: Int) -> List[UInt8]:
    """`{"name":"a"}` followed by spaces, `n` bytes in all."""
    var out = List('{"name":"a"}'.as_bytes())
    while len(out) < n:
        out.append(0x20)
    return out^


struct Plain(FromBody):  # declares nothing: the trait's 1 MiB
    var n: Int

    def __init__(out self, n: Int):
        self.n = n

    @staticmethod
    def from_body(body: String) raises -> Self:
        _bump(FROM_BODY_CALLS)
        return Self(body.byte_length())


struct Small(FromBody):
    comptime max_bytes = 8

    var n: Int

    def __init__(out self, n: Int):
        self.n = n

    @staticmethod
    def from_body(body: String) raises -> Self:
        _bump(FROM_BODY_CALLS)
        return Self(body.byte_length())


struct Zero(FromBody):
    comptime max_bytes = 0

    var n: Int

    def __init__(out self, n: Int):
        self.n = n

    @staticmethod
    def from_body(body: String) raises -> Self:
        _bump(FROM_BODY_CALLS)
        return Self(body.byte_length())


struct Unlimited(FromBody):
    comptime max_bytes = Int.MAX

    var n: Int

    def __init__(out self, n: Int):
        self.n = n

    @staticmethod
    def from_body(body: String) raises -> Self:
        _bump(FROM_BODY_CALLS)
        return Self(body.byte_length())


struct Misspelled(FromBody):
    comptime max_byte = Int.MAX  # not the member: the 1 MiB default holds

    var n: Int

    def __init__(out self, n: Int):
        self.n = n

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body.byte_length())


@fieldwise_init
struct Item(JsonFields):
    var name: String


def plain(body: Plain) -> String:
    _bump(HANDLER_CALLS)
    return String(body.n)


def small(id: Int, body: Small) -> String:
    _bump(HANDLER_CALLS)
    return String(id, ":", body.n)


def zero(body: Zero) -> String:
    return String(body.n)


def unlimited(body: Unlimited) -> String:
    return String(body.n)


def misspelled(body: Misspelled) -> String:
    return String(body.n)


def small_carried(input: WithHeaders[Small]) -> String:
    _bump(HANDLER_CALLS)
    return String(input.body.n)


def item(body: Json[Item]) -> String:
    return body.value.name


def tiny_item(body: Json[Item, limit=32]) -> String:
    _bump(HANDLER_CALLS)
    return body.value.name


def tiny_item_carried(
    id: Int, input: WithHeaders[Json[Item, limit=32]]
) -> String:
    _bump(HANDLER_CALLS)
    return String(id, ":", input.body.value.name)


def big_item(body: Json[Item, limit=2 * MIB]) -> String:
    return body.value.name


def echo_item() -> Json[Item, limit=4]:  # limit means nothing on a result
    return Json[Item, limit=4](Item("a long name"))


def inferred() -> Json[Item]:
    return Json(Item("x"), status=201)  # inferred as Json[Item]


def raw_tiny(req: Request) raises -> Response:
    var text = String(from_utf8=Span(req.body))
    try:
        return Response.text(Json[Item, limit=32].from_body(text).value.name)
    except e:
        return Response.text(String("raised: ", e))


def shrink(var request: Request, var next: Next) raises -> Response:
    if request.path == "/small/1" and len(request.body) > 8:
        request.body = _filled(8)
    return next^.run(request^)


struct Counter(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


def put_small(counter: State[Counter], id: Int, body: Small) -> String:
    return String(counter[].n, ":", id, ":", body.n)


def patch_small(counter: State[Counter], body: Small) -> String:
    return String(counter[].n, ":", body.n)


def widest(body: Json[Item, limit=4_294_967_295]) -> String:
    return body.value.name


def make_app() -> App:
    var app = App()
    app.use(shrink)
    app.post["/plain"](plain)
    app.post["/small/{id}"](small)
    app.post["/zero"](zero)
    app.post["/unlimited"](unlimited)
    app.post["/misspelled"](misspelled)
    app.post["/small-carried"](small_carried)
    app.post["/item"](item)
    app.post["/tiny"](tiny_item)
    app.post["/tiny/{id}"](tiny_item_carried)
    app.post["/big"](big_item)
    app.get["/echo"](echo_item)
    app.get["/inferred"](inferred)
    app.post["/raw"](raw_tiny)
    var counter = State(Counter(5))
    app.put["/small/{id}"](put_small, counter)
    app.patch["/small"](patch_small, counter)
    app.post["/widest"](widest)
    return app^


def test_text_limit_on_put_and_patch_with_state() raises:
    var app = make_app()
    var client = TestClient(app)
    assert_equal(client.put("/small/3", _filled(8)).text(), "5:3:8")
    assert_equal(client.put("/small/3", _filled(9)).status, 413)
    assert_equal(client.put("/small/x", _filled(9)).status, 400)
    assert_equal(client.patch("/small", _filled(8)).text(), "5:8")
    assert_equal(client.patch("/small", _filled(9)).status, 413)


def test_json_413_before_utf8_and_the_widest_limit() raises:
    var app = make_app()
    var client = TestClient(app)
    var bad = _padded(33)
    bad[10] = 0xFF  # inside the string: not UTF-8
    assert_equal(client.post("/tiny", bad.copy(), headers=_json()).status, 413)
    bad.resize(32, 0x20)
    assert_equal(client.post("/tiny", bad^, headers=_json()).status, 400)
    assert_equal(
        client.post("/widest", _padded(64), headers=_json()).text(), "a"
    )


def test_text_default_is_one_mib() raises:
    var app = make_app()
    var client = TestClient(app)
    _reset()
    assert_equal(client.post("/plain", _filled(MIB)).text(), String(MIB))
    var over = client.post("/plain", _filled(MIB + 1))
    assert_equal(over.status, 413)
    assert_equal(over.text(), "Content Too Large")
    assert_equal(_count(FROM_BODY_CALLS), 1)
    assert_equal(_count(HANDLER_CALLS), 1)
    # A misspelled member is not the limit: the default holds (fails closed).
    assert_equal(client.post("/misspelled", _filled(MIB + 1)).status, 413)


def test_text_declared_limit_zero_and_none() raises:
    var app = make_app()
    var client = TestClient(app)
    _reset()
    assert_equal(client.post("/small/2", _filled(8)).text(), "2:8")
    assert_equal(client.post("/small/2", _filled(9)).status, 413)
    assert_equal(_count(FROM_BODY_CALLS), 1)
    assert_equal(_count(HANDLER_CALLS), 1)
    assert_equal(client.post("/zero", List[UInt8]()).text(), "0")
    assert_equal(client.post("/zero", _filled(1)).status, 413)
    assert_equal(
        client.post("/unlimited", _filled(MIB + 1)).text(), String(MIB + 1)
    )


def test_text_order() raises:
    var app = make_app()
    var client = TestClient(app)
    # The route value's 400 first, whatever the length.
    assert_equal(client.post("/small/x", _filled(100)).status, 400)
    # 413 before the UTF-8 read: 9 bytes of 0xFF are 413, 8 are 400.
    assert_equal(client.post("/small/2", _filled(9, 0xFF)).status, 413)
    assert_equal(client.post("/small/2", _filled(8, 0xFF)).status, 400)
    # Measured after middleware: shrunk to 8 bytes, accepted.
    assert_equal(client.post("/small/1", _filled(100)).text(), "1:8")
    # Carried: 413 before the rebuild and from_body.
    _reset()
    assert_equal(client.post("/small-carried", _filled(8)).text(), "8")
    assert_equal(client.post("/small-carried", _filled(9)).status, 413)
    assert_equal(_count(FROM_BODY_CALLS), 1)


def test_json_default_and_limit() raises:
    var app = make_app()
    var client = TestClient(app)
    assert_equal(
        client.post("/item", _padded(MIB), headers=_json()).text(), "a"
    )
    assert_equal(
        client.post("/item", _padded(MIB + 1), headers=_json()).status, 413
    )
    _reset()
    assert_equal(client.post("/tiny", _padded(32), headers=_json()).text(), "a")
    var over = client.post("/tiny", _padded(33), headers=_json())
    assert_equal(over.status, 413)
    assert_equal(_count(HANDLER_CALLS), 1)
    # 415 before 413.
    assert_equal(client.post("/tiny", _padded(33)).status, 415)
    # Above the old fixed cap.
    assert_equal(
        client.post("/big", _padded(MIB + 1), headers=_json()).text(), "a"
    )
    assert_equal(
        client.post("/big", _padded(2 * MIB + 1), headers=_json()).status, 413
    )


def test_json_limit_carried() raises:
    var app = make_app()
    var client = TestClient(app)
    var h = _json()
    h.add("X-Trace", "t")
    assert_equal(
        client.post("/tiny/3", _padded(32), headers=h.copy()).text(), "3:a"
    )
    assert_equal(
        client.post("/tiny/3", _padded(33), headers=h.copy()).status, 413
    )
    assert_equal(client.post("/tiny/x", _padded(33), headers=h^).status, 400)


def test_json_limit_in_a_raw_handler_and_on_a_result() raises:
    var app = make_app()
    var client = TestClient(app)
    assert_equal(client.post("/raw", _padded(32)).text(), "a")
    assert_equal(
        client.post("/raw", _padded(33)).text(), "raised: JSON body too large"
    )
    assert_equal(client.get("/echo").text(), '{"name":"a long name"}')
    var r = client.get("/inferred")
    assert_equal(r.status, 201)
    assert_equal(r.text(), '{"name":"x"}')


def test_limits_read_at_compile_time() raises:
    assert_equal(Plain.max_bytes, MIB)
    assert_equal(Misspelled.max_bytes, MIB)
    assert_equal(Small.max_bytes, 8)
    assert_equal(Json[Item].max_bytes, MIB)
    assert_equal(Json[Item, limit=32].max_bytes, 32)
    assert_true(Json[Item, limit=MIB].max_bytes == Json[Item].max_bytes)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
