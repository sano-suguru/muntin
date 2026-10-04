# JSON bodies and results in production (M3-009): `muntin.Json`, `FromJson`,
# `ToJson`, `JsonValue` and `JsonWriter`, and the body adapters' `Content-Type`
# (415) and size (413) steps. Decision: docs/ARCHITECTURE.md, "JSON codec
# decision (M3-008)". Successful JSON-body requests go through
# `App.handle(Request(..., headers^))` with `Content-Type` set; `TestClient`
# sends no fields, so its `post` to a JSON-body route is pinned as 415, and
# routes that only return `Json[T]` go through `TestClient`. DX sections 4
# and 5: tests/test_json_dx.mojo. Must-not-compile cases: tests/json_api_fail.

from std.collections import Optional
from std.memory import bitcast
from std.os import getenv, setenv, unsetenv
from std.time import perf_counter_ns
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from muntin import (
    App,
    FromBody,
    FromJson,
    Headers,
    Json,
    JsonValue,
    JsonWriter,
    Request,
    Response,
    State,
    ToErrorResponse,
    ToJson,
)
from muntin.json import (
    _MAX_BODY_BYTES,
    _MAX_DEPTH,
    _json_content_type,
    _parse_json,
)
from muntin.testing import TestClient

comptime HANDLER = "MUNTIN_TEST_JSON_HANDLER"
comptime ERROR_CONVERSIONS = "MUNTIN_TEST_JSON_ERRORS"
comptime FAIL = "MUNTIN_TEST_JSON_FAIL"


def _reset():
    for name in [HANDLER, ERROR_CONVERSIONS, FAIL]:
        _ = unsetenv(name)


def _count(name: StaticString) -> Int:
    var n = getenv(name)
    try:
        return Int(n) if n else 0
    except:
        return -1


def _bump(name: StaticString):
    _ = setenv(name, String(_count(name) + 1))


# Application types.


@fieldwise_init
struct Address(Copyable, FromJson, ToJson):
    var city: String
    var zip: Int

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        return Self(value["city"].string(), value["zip"].int())

    def write_json(self, mut out: JsonWriter) raises:
        out.begin_object()
        out.name("city")
        out.string(self.city)
        out.name("zip")
        out.int(self.zip)
        out.end_object()


@fieldwise_init
struct CreateUser(FromJson):
    """Every supported kind: string, integer, boolean, float, list, an
    optional member (absent or null), a nested object and a list of
    objects."""

    var name: String
    var age: Int
    var admin: Bool
    var score: Float64
    var tags: List[String]
    var nickname: Optional[String]
    var home: Address
    var past: List[Address]

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        var tags = List[String]()
        var t = value["tags"]
        for i in range(len(t)):
            tags.append(t[i].string())
        var nickname = Optional[String]()
        var n = value.get("nickname")
        if n and not n.value().is_null():
            nickname = n.value().string()
        var past = List[Address]()
        var p = value["past"]
        for i in range(len(p)):
            past.append(Address.from_json(p[i]))
        return Self(
            value["name"].string(),
            value["age"].int(),
            value["admin"].bool(),
            value["score"].float(),
            tags^,
            nickname^,
            Address.from_json(value["home"]),
            past^,
        )


@fieldwise_init
struct User(ToJson):
    var id: Int
    var name: String
    var admin: Bool
    var score: Float64
    var tags: List[String]
    var nickname: Optional[String]
    var home: Address
    var past: List[Address]

    def write_json(self, mut out: JsonWriter) raises:
        out.begin_object()
        out.name("id")
        out.int(self.id)
        out.name("name")
        out.string(self.name)
        out.name("admin")
        out.bool(self.admin)
        out.name("score")
        out.float(self.score)
        out.name("tags")
        out.begin_array()
        for t in self.tags:
            out.string(t)
        out.end_array()
        out.name("nickname")
        if self.nickname:
            out.string(self.nickname.value())
        else:
            out.null()
        out.name("home")
        out.value(self.home)
        out.name("past")
        out.begin_array()
        for a in self.past:
            out.value(a)
        out.end_array()
        out.end_object()


def _user(id: Int, body: CreateUser) -> User:
    return User(
        id,
        body.name,
        body.admin,
        body.score,
        body.tags.copy(),
        body.nickname.copy(),
        body.home.copy(),
        body.past.copy(),
    )


@fieldwise_init
struct Directory(Movable):
    var offset: Int


# The eight typed body shapes: stateless and stateful, body only and `Int`
# then body, each with both result policies (`Json[User]` and `String`).


def create_user(var body: Json[CreateUser]) -> Json[User]:
    _bump(HANDLER)
    return Json(_user(1, body^.take()))


def create_user_text(body: Json[CreateUser]) -> String:
    _bump(HANDLER)
    return "created " + body.value.name


def update_user(id: Int, var body: Json[CreateUser]) -> Json[User]:
    _bump(HANDLER)
    return Json(_user(id, body^.take()))


def update_user_text(id: Int, body: Json[CreateUser]) -> String:
    _bump(HANDLER)
    return "updated " + String(id) + " " + body.value.name


def staff_create(
    dir: State[Directory], var body: Json[CreateUser]
) -> Json[User]:
    _bump(HANDLER)
    return Json(_user(dir[].offset, body^.take()))


def staff_create_text(dir: State[Directory], body: Json[CreateUser]) -> String:
    _bump(HANDLER)
    return "staff " + String(dir[].offset) + " " + body.value.name


def staff_update(
    dir: State[Directory], id: Int, var body: Json[CreateUser]
) -> Json[User]:
    _bump(HANDLER)
    return Json(_user(dir[].offset + id, body^.take()))


def staff_update_text(
    dir: State[Directory], id: Int, body: Json[CreateUser]
) -> String:
    _bump(HANDLER)
    return "staff " + String(dir[].offset + id) + " " + body.value.name


struct Token(FromJson, ToJson):
    """Move-only: no `Copyable`. Moved from the body into the result."""

    var secret: String

    def __init__(out self, var secret: String):
        self.secret = secret^

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        return Self(value["secret"].string())

    def write_json(self, mut out: JsonWriter) raises:
        out.begin_object()
        out.name("secret")
        out.string(self.secret)
        out.end_object()


def echo_token(var body: Json[Token]) -> Json[Token]:
    _bump(HANDLER)
    return Json(body^.take())


def peek_token(body: Json[Token]) -> String:
    return body.value.secret


def raw_token(var req: Request) raises -> Response:
    # A raw handler decodes with `Json[T].from_body` itself: no Content-Type
    # or size step runs before it, and the parser's cap raises into the
    # handler's own error model (here: the fixed 500).
    var body = Json[Token].from_body(req.body)
    return Response.text(body.value.secret)


def raw_token_mapped(var req: Request) -> Response:
    # The same decode with the application's own answer to a failure.
    try:
        return Response.text(Json[Token].from_body(req.body).value.secret)
    except:
        return Response.text("rejected", status=422)


def get_address(id: Int) -> Json[Address]:
    return Json(Address("Paris", id))


def get_staff(dir: State[Directory], id: Int) -> Json[Address]:
    return Json(Address("Oslo", dir[].offset + id))


@fieldwise_init
struct Note(FromBody):
    """An application body that is not JSON: no Content-Type, no cap."""

    var text: String

    @staticmethod
    def from_body(body: String) raises -> Self:
        if body == "fail":
            raise Error("bad note")
        return Self(body)


def note(body: Note) -> Response:
    return Response.text(body.text)


def note_int(id: Int, body: Note) -> String:
    return String(id) + ":" + String(body.text.byte_length())


def staff_note(dir: State[Directory], body: Note) -> String:
    return String(dir[].offset) + ":" + String(body.text.byte_length())


def note_address(body: Note) -> Json[Address]:
    return Json(Address(body.text, 1))


@fieldwise_init
struct Measurement(ToJson):
    var value: Float64

    def write_json(self, mut out: JsonWriter) raises:
        out.begin_object()
        out.name("value")
        out.float(self.value)
        out.end_object()


@fieldwise_init
struct Unbalanced(ToJson):
    def write_json(self, mut out: JsonWriter) raises:
        out.begin_object()


@fieldwise_init
struct Repeated(ToJson):
    def write_json(self, mut out: JsonWriter) raises:
        out.begin_object()
        out.name("a")
        out.int(1)
        out.name("a")
        out.int(2)
        out.end_object()


@fieldwise_init
struct Refusing(ToJson):
    def write_json(self, mut out: JsonWriter) raises:
        raise Error("cannot write")


@fieldwise_init
struct AppError(ToErrorResponse):
    def to_error_response(var self) -> Response:
        _bump(ERROR_CONVERSIONS)
        return Response.text("teapot", status=418)


def measure(id: Int) raises AppError -> Json[Measurement]:
    _bump(HANDLER)
    if getenv(FAIL) != "":
        raise AppError()
    if id == 0:
        return Json(Measurement(Float64(0) / Float64(0)))
    if id == 1:
        return Json(Measurement(Float64(1e300) * 1e300))
    return Json(Measurement(1.5))


def unbalanced() raises AppError -> Json[Unbalanced]:
    return Json(Unbalanced())


def repeated() raises AppError -> Json[Repeated]:
    return Json(Repeated())


def refusing() raises AppError -> Json[Refusing]:
    return Json(Refusing())


def staff_measure(
    dir: State[Directory], var body: Json[Token]
) raises AppError -> Json[Measurement]:
    _bump(HANDLER)
    return Json(Measurement(Float64(0) / Float64(0)))


def created() raises -> Response:
    # Explicit override: convert, then set status and fields; a `set` after
    # the conversion replaces the codec's Content-Type.
    var r = Json(Address("Rome", 7)).to_response()
    r.status = 201
    r.headers.set("Content-Type", "application/problem+json")
    return r^


def hello() -> String:
    return "hello"


def health() -> Response:
    return Response.text("ok")


def json_app() raises -> App:
    var dir = State(Directory(100))
    var app = App()
    app.post["/users"](create_user)
    app.post["/users-text"](create_user_text)
    app.post["/users/{id}"](update_user)
    app.post["/users-text/{id}"](update_user_text)
    app.post["/query?{id}"](update_user)
    app.post["/staff"](staff_create, dir)
    app.post["/staff-text"](staff_create_text, dir)
    app.post["/staff/{id}"](staff_update, dir)
    app.post["/staff-text/{id}"](staff_update_text, dir)
    app.post["/staff-query?{id}"](staff_update, dir)
    app.post["/tokens"](echo_token)
    app.post["/peek"](peek_token)
    app.post["/raw"](raw_token)
    app.post["/raw-mapped"](raw_token_mapped)
    app.post["/notes"](note)
    app.post["/notes/{id}"](note_int)
    app.post["/staff-notes"](staff_note, dir)
    app.post["/note-address"](note_address)
    app.post["/staff-measure"](staff_measure, dir)
    app.get["/addresses/{id}"](get_address)
    app.get["/staff/{id}"](get_staff, dir)
    app.get["/measure/{id}"](measure)
    app.get["/unbalanced"](unbalanced)
    app.get["/repeated"](repeated)
    app.get["/refusing"](refusing)
    app.get["/created"](created)
    app.get["/hello"](hello)
    app.get["/health"](health)
    return app^


comptime BODY = (
    '{"name":"Ada \\"L\\"\\u00e9\\ud83d\\ude00","age":36,"admin":true,'
    + '"score":-1.5e2,"tags":["a","b\\n"],"nickname":null,'
    + '"home":{"city":"X","zip":1},"past":[{"city":"Y","zip":2}],'
    + '"extra":[1,{"ignored":true}]}'
)
comptime USER_TAIL = (
    '"name":"Ada \\"L\\"é😀","admin":true,"score":-150.0,'
    + '"tags":["a","b\\n"],"nickname":null,"home":{"city":"X","zip":1},'
    + '"past":[{"city":"Y","zip":2}]}'
)
comptime NAME = 'Ada "L"é😀'


def _user_json(id: Int) -> String:
    return '{"id":' + String(id) + "," + USER_TAIL


def _post(
    app: App,
    target: String,
    body: String,
    content_type: String = "application/json",
) raises -> Response:
    """`App.handle` for `POST target` with one `Content-Type` field, or none
    when `content_type` is empty."""
    var h = Headers()
    if content_type.byte_length() > 0:
        h.add("Content-Type", content_type)
    return app.handle(Request("POST", target, body, h^))


def _post_fields(
    app: App, target: String, body: String, var headers: Headers
) -> Response:
    return app.handle(Request("POST", target, body, headers^))


# (target, expected body) for one request with BODY on each JSON body shape.
def _shapes() -> List[Tuple[String, String]]:
    var s = List[Tuple[String, String]]()
    s.append((String("/users"), _user_json(1)))
    s.append((String("/users-text"), "created " + NAME))
    s.append((String("/users/9"), _user_json(9)))
    s.append((String("/users-text/9"), "updated 9 " + NAME))
    s.append((String("/query?id=9"), _user_json(9)))
    s.append((String("/staff"), _user_json(100)))
    s.append((String("/staff-text"), "staff 100 " + NAME))
    s.append((String("/staff/9"), _user_json(109)))
    s.append((String("/staff-text/9"), "staff 109 " + NAME))
    s.append((String("/staff-query?id=9"), _user_json(109)))
    return s^


def _is_json_result(target: String) -> Bool:
    return target.find("-text") < 0


def _assert_fixed(r: Response, status: Int, body: String) raises:
    assert_equal(r.status, status)
    assert_equal(r.body, body)
    assert_equal(len(r.headers), 0)


def test_json_bodies_on_every_typed_shape() raises:
    # Body only and `Int` then body (path and query), stateless and
    # stateful, with both result policies, through the existing overloads.
    var app = json_app()
    for s in _shapes():
        var target = s[0]
        _reset()
        var r = _post(app, target, BODY)
        assert_equal(r.status, 200, target)
        assert_equal(r.body, s[1], target)
        if _is_json_result(target):
            assert_equal(len(r.headers), 1, target)
            assert_equal(r.headers.name(0), "Content-Type")
            assert_equal(r.headers.value(0), "application/json")
        else:
            assert_equal(len(r.headers), 0, target)
        assert_equal(_count(HANDLER), 1, target)


def test_representative_round_trip_kinds() raises:
    var c = Json[CreateUser].from_body(BODY).take()
    assert_equal(c.name, NAME)
    assert_equal(c.age, 36)
    assert_true(c.admin)
    assert_equal(c.score, -150.0)
    assert_equal(len(c.tags), 2)
    assert_equal(c.tags[1], "b\n")
    assert_false(Bool(c.nickname))
    assert_equal(c.home.zip, 1)
    assert_equal(c.past[0].city, "Y")
    # A present nickname, then absent and null told apart.
    var named = String(BODY).replace('"nickname":null', '"nickname":"Al"')
    assert_equal(Json[CreateUser].from_body(named).value.nickname.value(), "Al")
    assert_false(Bool(_parse_json('{"a":1}').get("nickname")))
    assert_true(_parse_json('{"n":null}')["n"].is_null())
    assert_true(Bool(_parse_json('{"n":null}').get("n")))
    # Top-level scalars and arrays are JSON texts too (RFC 8259).
    assert_equal(_parse_json(" 42 ").int(), 42)
    assert_equal(_parse_json("[true,false,null]")[1].bool(), False)
    assert_true(_parse_json("[true,false,null]")[2].is_null())
    assert_equal(len(_parse_json("[true,false,null]")), 3)
    assert_equal(len(_parse_json("1")), 0)
    assert_equal(_parse_json('"x"').string(), "x")
    assert_equal(_parse_json('"\\/\\b\\f\\r\\t"').string(), "/\x08\x0c\r\t")
    assert_equal(_parse_json('{"\\u0061":1}')["a"].int(), 1)
    assert_equal(_parse_json("-0").int(), 0)
    assert_equal(_parse_json("0.5e-1").float(), 0.05)
    assert_equal(_parse_json("2").float(), 2.0)
    # Accessors of the wrong kind raise.
    var v = _parse_json('{"a":[1],"s":"x","n":1.5}')
    for k in range(8):
        var raised = False
        try:
            if k == 0:
                _ = v["a"].int()
            elif k == 1:
                _ = v["s"].float()
            elif k == 2:
                _ = v["n"].string()
            elif k == 3:
                _ = v["a"][1]
            elif k == 4:
                _ = v["s"][0]
            elif k == 5:
                _ = v["a"]["x"]
            elif k == 6:
                _ = v["missing"]
            else:
                _ = v["s"].bool()
        except:
            raised = True
        assert_true(raised, String(k))


comptime MALFORMED: List[String] = [
    "",
    " ",
    "{",
    '{"a":1,}',
    "[1,]",
    "{'a':1}",
    '{"a":1} x',
    '{"a":1}{"b":2}',
    "// c\n{}",
    "/* c */{}",
    "01",
    "+1",
    "1.",
    ".5",
    "1e",
    "NaN",
    "Infinity",
    "-Infinity",
    "tru",
    "nul",
    "TRUE",
    '"a\tb"',
    '"a\nb"',
    '"\\x"',
    '"\\u12"',
    '"\\ud800"',
    '"\\udc00"',
    '"\\ud800\\u0041"',
    '"unterminated',
    '{"a" 1}',
    "{a:1}",
    '{"a":1,"a":2}',
    "﻿{}",
    "[1 2]",
]


def test_malformed_json_is_400_before_the_handler() raises:
    var app = json_app()
    assert_equal(len(materialize[MALFORMED]()), 34)
    for s in materialize[MALFORMED]():
        var raised = False
        try:
            _ = _parse_json(s)
        except:
            raised = True
        assert_true(raised, "parsed: " + s)
        for target in ["/users", "/users/1", "/staff", "/staff/1"]:
            _reset()
            var r = _post(app, target, s)
            _assert_fixed(r, 400, "Bad Request")
            assert_equal(_count(HANDLER), 0, s)
    # Duplicates are found after escapes are decoded, and per object.
    for s in ['{"a":1,"\\u0061":2}', '{"x":{"b":1,"b":2}}']:
        _reset()
        assert_equal(_post(app, "/users", s).status, 400, s)
        assert_equal(_count(HANDLER), 0)
    _ = _parse_json('{"a":{"a":1},"b":{"a":2}}')


def test_field_errors_are_400_and_extra_members_are_ignored() raises:
    var app = json_app()
    for s in [
        '{"name":"A"}',
        '{"name":1,"age":1,"admin":true,"score":1,"tags":[],"home":{"city":"","zip":0},"past":[]}',
        '{"name":"A","age":1.5,"admin":true,"score":1,"tags":[],"home":{"city":"","zip":0},"past":[]}',
        '{"name":"A","age":1e2,"admin":true,"score":1,"tags":[],"home":{"city":"","zip":0},"past":[]}',
        '{"name":"A","age":99999999999999999999,"admin":true,"score":1,"tags":[],"home":{"city":"","zip":0},"past":[]}',
        '{"name":"A","age":1,"admin":"yes","score":1,"tags":[],"home":{"city":"","zip":0},"past":[]}',
        '{"name":"A","age":1,"admin":true,"score":1e400,"tags":[],"home":{"city":"","zip":0},"past":[]}',
        '{"name":"A","age":1,"admin":true,"score":1,"tags":[1],"home":{"city":"","zip":0},"past":[]}',
        '{"name":"A","age":1,"admin":true,"score":1,"tags":[],"home":[],"past":[]}',
        '{"name":"A","age":1,"admin":true,"score":1,"tags":[],"home":{"city":"","zip":0},"past":[{"city":"Y"}]}',
        "[]",
        "null",
    ]:
        for target in ["/users", "/users-text/2", "/staff-text", "/staff/2"]:
            _reset()
            var r = _post(app, target, s)
            _assert_fixed(r, 400, "Bad Request")
            assert_equal(_count(HANDLER), 0, s)
    _reset()
    var ok = '{"name":"A","age":1,"admin":false,"score":1,"tags":[],"home":{"city":"","zip":0},"past":[],"zzz":{"deep":[1,2,3]}}'
    assert_equal(_post(app, "/users-text", ok).body, "created A")
    assert_equal(_count(HANDLER), 1)


def _nested(depth: Int) -> String:
    var s = String()
    for _ in range(depth):
        s += "["
    for _ in range(depth):
        s += "]"
    return s^


def test_nesting_cap() raises:
    _ = _parse_json(_nested(_MAX_DEPTH))
    assert_equal(_MAX_DEPTH, 64)
    var raised = False
    try:
        _ = _parse_json(_nested(_MAX_DEPTH + 1))
    except:
        raised = True
    assert_true(raised)
    # Through a route: the parse fails, so 400 before the handler.
    var app = json_app()
    _reset()
    _assert_fixed(
        _post(app, "/tokens", _nested(_MAX_DEPTH + 1)), 400, "Bad Request"
    )
    assert_equal(_count(HANDLER), 0)


comptime ACCEPTED: List[String] = [
    "application/json",
    "Application/JSON",
    "APPLICATION/JSON",
    "application/json; charset=utf-8",
    "application/json;charset=UTF-8",
    "application/json ; charset=utf-8",
    "application/json; charset=latin1",
    "application/json;",
]
comptime REFUSED: List[String] = [
    "text/plain",
    "text/plain; charset=utf-8",
    "application/problem+json",
    "application/vnd.api+json",
    "application/jsonx",
    "application/json-patch+json",
    "application/x-www-form-urlencoded",
    "multipart/form-data; boundary=x",
    "application",
    "json",
    "applİcation/json",
    "APPLİCATION/JSON",
    "application/ json",
    "application /json",
]


def test_request_content_type_rule() raises:
    for v in materialize[ACCEPTED]():
        var h = Headers()
        h.add("Content-Type", v)
        assert_true(_json_content_type(h), v)
    for v in materialize[REFUSED]():
        var h = Headers()
        h.add("Content-Type", v)
        assert_false(_json_content_type(h), v)
    assert_false(_json_content_type(Headers()))
    var empty = Headers()
    empty.add("Content-Type", "")
    assert_false(_json_content_type(empty))
    var two = Headers()
    two.add("Content-Type", "application/json")
    two.add("content-type", "application/json")
    assert_false(_json_content_type(two))
    var lower = Headers()
    lower.add("content-type", "application/json")
    lower.add("Accept", "text/plain")
    assert_true(_json_content_type(lower))


def test_content_type_is_415_on_every_json_body_shape() raises:
    var app = json_app()
    for s in _shapes():
        var target = s[0]
        for v in materialize[ACCEPTED]():
            _reset()
            var r = _post(app, target, BODY, v)
            assert_equal(r.status, 200, target + " " + v)
            assert_equal(r.body, s[1])
            assert_equal(_count(HANDLER), 1)
        for v in materialize[REFUSED]():
            _reset()
            _assert_fixed(
                _post(app, target, BODY, v), 415, "Unsupported Media Type"
            )
            assert_equal(_count(HANDLER), 0, target + " " + v)
        # Missing, empty, and two fields (same or different values).
        _reset()
        _assert_fixed(
            _post(app, target, BODY, ""), 415, "Unsupported Media Type"
        )
        var empty = Headers()
        empty.add("Content-Type", "")
        _assert_fixed(
            _post_fields(app, target, BODY, empty^),
            415,
            "Unsupported Media Type",
        )
        var two = Headers()
        two.add("Content-Type", "application/json")
        two.add("content-type", "application/json")
        _assert_fixed(
            _post_fields(app, target, BODY, two^),
            415,
            "Unsupported Media Type",
        )
        var mixed = Headers()
        mixed.add("Content-Type", "application/json")
        mixed.add("Content-Type", "text/plain")
        _assert_fixed(
            _post_fields(app, target, BODY, mixed^),
            415,
            "Unsupported Media Type",
        )
        assert_equal(_count(HANDLER), 0, target)


def test_testclient_post_to_a_json_body_route_is_415() raises:
    # `TestClient.post` sends no Content-Type: pinned, an accepted cost of
    # requiring the field until TestClient can send fields.
    var app = json_app()
    var client = TestClient(app)
    for s in _shapes():
        _reset()
        _assert_fixed(client.post(s[0], BODY), 415, "Unsupported Media Type")
        assert_equal(_count(HANDLER), 0)


def _padded(body: String, size: Int) -> String:
    """`body` followed by spaces up to `size` bytes: still the same JSON."""
    return body + String(" ") * (size - body.byte_length())


def test_body_cap_on_every_json_body_shape() raises:
    # Exactly 1 MiB is parsed; one byte more is 413 before parsing, without
    # the handler.
    assert_equal(_MAX_BODY_BYTES, 1_048_576)
    var at_cap = _padded(BODY, _MAX_BODY_BYTES)
    var over = _padded(BODY, _MAX_BODY_BYTES + 1)
    assert_equal(at_cap.byte_length(), 1_048_576)
    var app = json_app()
    for s in _shapes():
        var target = s[0]
        _reset()
        var ok = _post(app, target, at_cap)
        assert_equal(ok.status, 200, target)
        assert_equal(ok.body, s[1])
        assert_equal(_count(HANDLER), 1)
        _reset()
        _assert_fixed(_post(app, target, over), 413, "Content Too Large")
        assert_equal(_count(HANDLER), 0, target)
    # At the cap, malformed JSON reaches the parser (400); over it, the
    # size step answers first (413 before JSON 400).
    var bad_at_cap = _padded("{", _MAX_BODY_BYTES)
    var bad_over = _padded("{", _MAX_BODY_BYTES + 1)
    for target in ["/users", "/users/1", "/staff", "/staff/1"]:
        _reset()
        _assert_fixed(_post(app, target, bad_at_cap), 400, "Bad Request")
        _assert_fixed(_post(app, target, bad_over), 413, "Content Too Large")
        assert_equal(_count(HANDLER), 0)


def test_request_order_on_json_body_routes() raises:
    # 404 -> query 400 -> route-value 400 -> 415 -> 413 -> JSON 400 ->
    # handler, each step measured with every later failure present.
    var app = json_app()
    var over = _padded("{", _MAX_BODY_BYTES + 1)
    _reset()
    assert_equal(_post(app, "/nowhere", over, "text/plain").status, 404)
    assert_equal(_post(app, "/users/", BODY).status, 404)
    for prefix in ["/query", "/staff-query"]:
        var p = String(prefix)
        # Query value missing, duplicated or invalid: 400 in App.handle,
        # before the 415 and 413 steps.
        for q in ["", "?x=1", "?id=1&id=2", "?id=abc", "?id="]:
            _assert_fixed(
                _post(app, p + q, over, "text/plain"), 400, "Bad Request"
            )
        _assert_fixed(
            _post(app, p + "?id=1", over, "text/plain"),
            415,
            "Unsupported Media Type",
        )
        _assert_fixed(_post(app, p + "?id=1", over), 413, "Content Too Large")
        _assert_fixed(_post(app, p + "?id=1", "{"), 400, "Bad Request")
    for prefix in ["/users/", "/users-text/", "/staff/", "/staff-text/"]:
        var p = String(prefix)
        # Route value: 400 before 415 and 413.
        _assert_fixed(
            _post(app, p + "abc", over, "text/plain"), 400, "Bad Request"
        )
        _assert_fixed(_post(app, p + "abc", over), 400, "Bad Request")
        _assert_fixed(_post(app, p + "abc", BODY, ""), 400, "Bad Request")
        # 415 before 413 and before JSON 400.
        _assert_fixed(
            _post(app, p + "1", over, "text/plain"),
            415,
            "Unsupported Media Type",
        )
        _assert_fixed(
            _post(app, p + "1", "{", ""), 415, "Unsupported Media Type"
        )
        # 413 before JSON 400.
        _assert_fixed(_post(app, p + "1", over), 413, "Content Too Large")
        _assert_fixed(_post(app, p + "1", "{"), 400, "Bad Request")
    for target in ["/users", "/users-text", "/staff", "/staff-text"]:
        _assert_fixed(
            _post(app, target, over, "text/plain"),
            415,
            "Unsupported Media Type",
        )
        _assert_fixed(
            _post(app, target, "{", ""), 415, "Unsupported Media Type"
        )
        _assert_fixed(_post(app, target, over), 413, "Content Too Large")
    assert_equal(_count(HANDLER), 0)


def test_move_only_body_and_result() raises:
    var app = json_app()
    _reset()
    var r = _post(app, "/tokens", '{"secret":"s3"}')
    assert_equal(r.status, 200)
    assert_equal(r.body, '{"secret":"s3"}')
    assert_equal(r.headers.get("content-type").value(), "application/json")
    assert_equal(_count(HANDLER), 1)
    # Borrowed: the handler reads `body.value`.
    assert_equal(_post(app, "/peek", '{"secret":"s4"}').body, "s4")
    # `take()` moves the value out of a `Json` the caller owns.
    var t = Json(Token("s5"))
    var token = t^.take()
    assert_equal(token.secret, "s5")


def test_raw_handler_decodes_with_from_body() raises:
    # A raw route runs no Content-Type or size step: the handler decodes
    # itself, and the parser's cap raises into its own error model.
    var app = json_app()
    var token = '{"secret":"r"}'
    assert_equal(_post(app, "/raw", token, "").body, "r")
    assert_equal(_post(app, "/raw", token, "text/plain").body, "r")
    var at_cap = _padded(token, _MAX_BODY_BYTES)
    var over = _padded(token, _MAX_BODY_BYTES + 1)
    assert_equal(_post(app, "/raw", at_cap).body, "r")
    _assert_fixed(_post(app, "/raw", over), 500, "Internal Server Error")
    _assert_fixed(_post(app, "/raw", "{", ""), 500, "Internal Server Error")
    assert_equal(_post(app, "/raw-mapped", at_cap).body, "r")
    _assert_fixed(_post(app, "/raw-mapped", over), 422, "rejected")
    # The cap is in the parser itself, wherever `from_body` is called.
    assert_equal(Json[Token].from_body(at_cap).value.secret, "r")
    var raised = False
    try:
        _ = Json[Token].from_body(over)
    except e:
        raised = True
        assert_equal(String(e), "JSON body too large")
    assert_true(raised)


def test_json_results_on_get_and_post() raises:
    # Routes that only return `Json[T]` test through TestClient: GET, the
    # stateful GET, and POST with a non-JSON body (no Content-Type needed).
    var app = json_app()
    var client = TestClient(app)
    for pair in [
        ("/addresses/5", '{"city":"Paris","zip":5}'),
        ("/staff/3", '{"city":"Oslo","zip":103}'),
    ]:
        var r = client.get(pair[0])
        assert_equal(r.status, 200)
        assert_equal(r.body, pair[1])
        assert_equal(len(r.headers), 1)
        assert_equal(r.headers.name(0), "Content-Type")
        assert_equal(r.headers.value(0), "application/json")
    var p = client.post("/note-address", 'Ri"ga')
    assert_equal(p.status, 200)
    assert_equal(p.body, '{"city":"Ri\\"ga","zip":1}')
    assert_equal(len(p.headers), 1)
    assert_equal(p.headers.value(0), "application/json")
    assert_equal(client.post("/note-address", "fail").status, 400)


def test_serialization_failure_is_not_a_handler_error() raises:
    # The handler returns; the writer raises (NaN, infinity, a repeated
    # name, the application's own raise) or is left unbalanced. The answer
    # is the fixed 500 without a Content-Type, and the handler's
    # `ToErrorResponse` is not called. A raised `AppError` still takes the
    # handler-error path (418).
    var app = json_app()
    var client = TestClient(app)
    for target in [
        "/measure/0",
        "/measure/1",
        "/unbalanced",
        "/repeated",
        "/refusing",
    ]:
        _reset()
        _assert_fixed(client.get(target), 500, "Internal Server Error")
        assert_equal(_count(ERROR_CONVERSIONS), 0, target)
    # Stateful POST with a JSON body: the same fixed 500.
    _reset()
    _assert_fixed(
        _post(app, "/staff-measure", '{"secret":"x"}'),
        500,
        "Internal Server Error",
    )
    assert_equal(_count(HANDLER), 1)
    assert_equal(_count(ERROR_CONVERSIONS), 0)
    _reset()
    _ = setenv(FAIL, "1")
    var e = client.get("/measure/2")
    assert_equal(e.status, 418)
    assert_equal(e.body, "teapot")
    assert_equal(_count(ERROR_CONVERSIONS), 1)
    _reset()
    assert_equal(client.get("/measure/2").body, '{"value":1.5}')


def test_explicit_response_override() raises:
    var app = json_app()
    var r = TestClient(app).get("/created")
    assert_equal(r.status, 201)
    assert_equal(r.body, '{"city":"Rome","zip":7}')
    assert_equal(len(r.headers), 1)
    assert_equal(
        r.headers.get("content-type").value(), "application/problem+json"
    )


def test_text_results_keep_no_default_fields() raises:
    var app = json_app()
    var client = TestClient(app)
    for target in ["/hello", "/health"]:
        var r = client.get(target)
        assert_equal(r.status, 200)
        assert_equal(len(r.headers), 0, target)
    assert_equal(len(Response.text("x").headers), 0)
    assert_equal(len(_post(app, "/users-text", BODY).headers), 0)


def test_non_json_bodies_are_unchanged_and_uncapped() raises:
    # An application `FromBody` route requires no Content-Type, has no cap,
    # receives the body unchanged, and keeps its 400.
    var app = json_app()
    var client = TestClient(app)
    var over = String("x") * (_MAX_BODY_BYTES + 1)
    var r = client.post("/notes", over)
    assert_equal(r.status, 200)
    assert_equal(r.body.byte_length(), _MAX_BODY_BYTES + 1)
    assert_equal(client.post("/notes", "{").body, "{")
    assert_equal(_post(app, "/notes", "hi", "text/plain").body, "hi")
    assert_equal(_post(app, "/notes", "hi").body, "hi")
    assert_equal(client.post("/notes/4", over).body, "4:1048577")
    assert_equal(client.post("/notes/x", "hi").status, 400)
    assert_equal(client.post("/staff-notes", over).body, "100:1048577")
    _assert_fixed(client.post("/notes", "fail"), 400, "Bad Request")
    _assert_fixed(client.post("/staff-notes", "fail"), 400, "Bad Request")


def test_number_limits_on_mojo_1_1_0() raises:
    # `float()` rejects overflow, and Mojo 1.1.0 `atof` rejects long literals
    # (by length and magnitude, even with one significant digit): both raise
    # (400 through a body). A pinned gap: valid JSON numbers a future `atof`
    # may accept.
    for s in [
        "1e400",
        "-1e400",
        "123456789012345678901234",
        "1.2345678901234567890123",
        "100000000000000000000000",
        "0.000000000000000000000000000001",
    ]:
        var raised = False
        try:
            _ = _parse_json(s).float()
        except:
            raised = True
        assert_true(raised, s)
    assert_equal(_parse_json("1e-400").float(), 0.0)
    assert_equal(_parse_json("9223372036854775807").int(), Int.MAX)
    assert_equal(_parse_json("-9223372036854775808").int(), Int.MIN)


def _bits(x: Float64) -> UInt64:
    return bitcast[DType.uint64](x)


def _written(value: Float64) raises -> String:
    var w = JsonWriter()
    w.float(value)
    return w^._finish()


def test_float_rounding_gaps_on_mojo_1_1_0() raises:
    # Pinned Mojo 1.1.0 behavior, each 1 ulp from the correctly rounded
    # value (Python's in the comments). `float()` uses `atof`; the writer
    # uses `String(Float64)`. A fix in the toolchain turns these red: revisit
    # (docs/ARCHITECTURE.md, "JSON codec decision (M3-008)").
    # Shortest-repr doubles as JS/Python clients send them: correct
    # 0xc42dddc22f41f7cd and 0x4429c9f9333a6521.
    assert_equal(
        _bits(_parse_json("-2.7546748226290886e+20").float()),
        UInt64(0xC42DDDC22F41F7CC),
    )
    assert_equal(
        _bits(_parse_json("2.3786116091973052e+20").float()),
        UInt64(0x4429C9F9333A6520),
    )
    # A long integer literal read as a float: correct 0x437b69b4ba630f35
    # (`int()` is exact).
    assert_equal(
        _bits(_parse_json("123456789012345678").float()),
        UInt64(0x437B69B4BA630F34),
    )
    assert_equal(_parse_json("123456789012345678").int(), 123456789012345678)
    # The writer's text does not always read back to the same double.
    var text = _written(bitcast[DType.float64](UInt64(0xC360B3B71251310B)))
    assert_equal(text, "-3.760958796054742e+16")
    assert_equal(_bits(_parse_json(text).float()), UInt64(0xC360B3B71251310C))
    # Finite floats print as valid JSON numbers.
    assert_equal(_written(1e16), "1e+16")
    assert_equal(_written(1e-07), "1e-07")
    assert_equal(_written(-150.0), "-150.0")


def test_writer_escapes_and_structure() raises:
    var w = JsonWriter()
    w.begin_object()
    w.name('q"\\')
    w.string("a\x01\x1f\t\r\n\x7f é")
    w.name("f")
    w.float(1e16)
    w.name("n")
    w.null()
    w.name("o")
    w.begin_object()
    w.name("a")
    w.int(1)
    w.end_object()
    w.name("o2")
    w.begin_object()
    w.name("a")
    w.int(2)
    w.end_object()
    w.name("l")
    w.begin_array()
    w.bool(True)
    w.begin_array()
    w.end_array()
    w.int(-3)
    w.end_array()
    w.end_object()
    var text = w^._finish()
    assert_equal(
        text,
        '{"q\\"\\\\":"a\\u0001\\u001f\\t\\r\\n\x7f é","f":1e+16,"n":null,'
        + '"o":{"a":1},"o2":{"a":2},"l":[true,[],-3]}',
    )
    # Muntin's parser reads back what the writer wrote.
    var v = _parse_json(text)
    assert_equal(v['q"\\'].string(), "a\x01\x1f\t\r\n\x7f é")
    assert_equal(v["l"][2].int(), -3)
    # Structural misuse and non-finite numbers raise.
    for i in range(11):
        var out = JsonWriter()
        var raised = False
        try:
            if i == 0:
                out.begin_object()
                out.int(1)
            elif i == 1:
                out.name("x")
            elif i == 2:
                out.end_array()
            elif i == 3:
                out.int(1)
                out.int(2)
            elif i == 4:
                out.float(Float64(0) / Float64(0))
            elif i == 5:
                out.begin_array()
                _ = out^._finish()
                out = JsonWriter()
                _ = out^._finish()
            elif i == 6:
                out.begin_object()
                out.name("a")
                out.int(1)
                out.name("a")
                out.int(2)
                out.end_object()
            elif i == 7:
                out.begin_object()
                out.name("a")
                out.name("b")
            elif i == 8:
                out.begin_object()
                out.name("a")
                out.end_object()
            elif i == 9:
                out.begin_array()
                out.end_object()
            else:
                _ = out^._finish()
                out = JsonWriter()
                _ = out^._finish()
        except:
            raised = True
        assert_true(raised, String(i))


def test_parsing_and_access_are_linear() raises:
    # Cost oracle for hostile bodies under the 1 MiB cap: an 80k-member
    # object (duplicate-name check) and a 200k-element array read by index.
    # A quadratic parser or element access takes minutes here; the bound is
    # generous.
    var members = List[String]()
    for i in range(80_000):
        members.append('"k' + String(i) + '":0')
    var obj = "{" + ",".join(members) + "}"
    var elements = List[String]()
    for _ in range(200_000):
        elements.append('"a"')
    var arr = "[" + ",".join(elements) + "]"
    assert_true(obj.byte_length() <= _MAX_BODY_BYTES)
    assert_true(arr.byte_length() <= _MAX_BODY_BYTES)
    var t0 = perf_counter_ns()
    var o = _parse_json(obj)
    var a = _parse_json(arr)
    var total = 0
    for i in range(len(a)):
        total += a[i].string().byte_length()
    _ = o["k79999"].int()
    var ms = Int((perf_counter_ns() - t0) // 1_000_000)
    assert_equal(len(o), 80_000)
    assert_equal(total, 200_000)
    assert_true(ms < 2_000, String(ms) + " ms")


def test_json_value_copies_share_the_document() raises:
    # One tape per parse; a sub-value copies one reference, not the tape;
    # string accessors return copies.
    var v = _parse_json('{"a":{"b":[1,2]}}')
    assert_equal(v._doc.count(), 1)
    var a = v["a"]
    var b = a["b"]
    assert_equal(v._doc.count(), 3)
    assert_equal(b[1].int(), 2)
    _ = a^
    _ = b^
    assert_equal(v._doc.count(), 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
