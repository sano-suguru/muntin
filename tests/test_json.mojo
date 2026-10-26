# JSON bodies and results in production (M3-009): `muntin.Json`, `FromJson`,
# `ToJson`, `JsonValue` and `JsonWriter`, and the body adapters' `Content-Type`
# (415) and size (413) steps; `Json[T, limit=n]` (M3-089). Decision: docs/history/architecture-decisions.md,
# "JSON codec decision (M3-008)". Successful JSON-body requests go through
# `App.handle(Request(..., headers^))` with `Content-Type` set; the bare
# `TestClient.post(target, body)` sends no fields, so its answer on a JSON-body
# route is pinned as 415, and routes that only return `Json[T]` go through
# `TestClient`. `TestClient`'s `headers=` (M3-011):
# tests/test_testclient_headers.mojo. The reference's JSON examples:
# tests/test_json_dx.mojo. Must-not-compile cases: tests/json_api_fail. A chosen
# result status, `Json(value, status=)`: M3-029.

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
    WithHeaders,
)
from muntin.json import (
    _MAX_BODY_BYTES,
    _MAX_DEPTH,
    _json_content_type,
    _parse_json,
    _to_float64,
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


# The same eight shapes, and two in a carrier, with a chosen limit
# (`Json[T, limit=n]`, M3-089); `n` is instantiated at registration.


def l_create[n: Int](var body: Json[CreateUser, limit=n]) -> Json[User]:
    _bump(HANDLER)
    return Json(_user(1, body^.take()))


def l_create_text[n: Int](body: Json[CreateUser, limit=n]) -> String:
    _bump(HANDLER)
    return "created " + body.value.name


def l_update[
    n: Int
](id: Int, var body: Json[CreateUser, limit=n]) -> Json[User]:
    _bump(HANDLER)
    return Json(_user(id, body^.take()))


def l_update_text[n: Int](id: Int, body: Json[CreateUser, limit=n]) -> String:
    _bump(HANDLER)
    return "updated " + String(id) + " " + body.value.name


def l_staff_create[
    n: Int
](dir: State[Directory], var body: Json[CreateUser, limit=n]) -> Json[User]:
    _bump(HANDLER)
    return Json(_user(dir[].offset, body^.take()))


def l_staff_create_text[
    n: Int
](dir: State[Directory], body: Json[CreateUser, limit=n]) -> String:
    _bump(HANDLER)
    return "staff " + String(dir[].offset) + " " + body.value.name


def l_staff_update[
    n: Int
](dir: State[Directory], id: Int, var body: Json[CreateUser, limit=n]) -> Json[
    User
]:
    _bump(HANDLER)
    return Json(_user(dir[].offset + id, body^.take()))


def l_staff_update_text[
    n: Int
](dir: State[Directory], id: Int, body: Json[CreateUser, limit=n]) -> String:
    _bump(HANDLER)
    return "staff " + String(dir[].offset + id) + " " + body.value.name


def l_carried[
    n: Int
](id: Int, input: WithHeaders[Json[CreateUser, limit=n]]) -> String:
    _bump(HANDLER)
    return "updated " + String(id) + " " + input.body.value.name


def l_staff_carried[
    n: Int
](
    dir: State[Directory], var input: WithHeaders[Json[CreateUser, limit=n]]
) -> Json[User]:
    _bump(HANDLER)
    return Json(_user(dir[].offset, input^.take_body().take()))


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
    var body = Json[Token].from_body(req.text())
    return Response.text(body.value.secret)


def raw_token_mapped(var req: Request) -> Response:
    # The same decode with the application's own answer to a failure.
    try:
        return Response.text(Json[Token].from_body(req.text()).value.secret)
    except:
        return Response.text("rejected", status=422)


def get_address(id: Int) -> Json[Address]:
    return Json(Address("Paris", id))


def get_staff(dir: State[Directory], id: Int) -> Json[Address]:
    return Json(Address("Oslo", dir[].offset + id))


@fieldwise_init
struct Note(FromBody):
    """An application body that is not JSON: no Content-Type, and
    `FromBody`'s 1 MiB default (M3-089)."""

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


def created_address(id: Int) -> Json[Address]:
    # `get_address`'s value with a chosen status.
    return Json(Address("Paris", id), status=201)


def teapot_address(id: Int) -> Json[Address]:
    return Json(Address("Paris", id), status=418)


def measure_created(id: Int) -> Json[Measurement]:
    if id == 0:
        return Json(Measurement(Float64(0) / Float64(0)), status=201)
    return Json(Measurement(1.5), status=201)


def refusing_created() -> Json[Refusing]:
    return Json(Refusing(), status=201)


def explicit_address(id: Int) -> Json[Address]:
    return Json[Address](Address("Paris", id))


def unvalidated_address(id: Int) -> Json[Address]:
    # Not a valid HTTP status: Muntin passes it on, as for `Response`.
    return Json(Address("Paris", id), status=999)


def status_set_after_failure() raises -> Response:
    # docs/reference/responses.md: an edit after `to_response()` applies to
    # the fixed 500.
    var r = Json(Measurement(Float64(0) / Float64(0))).to_response()
    r.status = 201
    return r^


def media_type_after_failure() raises -> Response:
    # docs/reference/responses.md's media-type example, with a value that
    # fails to write.
    var r = Json(Measurement(Float64(0) / Float64(0)), status=201).to_response()
    r.headers.set("Content-Type", "application/problem+json")
    return r^


def return_body(var body: Json[Token]) -> Json[Token]:
    # The body `from_body` built is returned as it is: the default status.
    return body^


def create_token(var body: Json[Token]) -> Json[Token]:
    _bump(HANDLER)
    return Json(body^.take(), status=201)


def staff_token(dir: State[Directory], var body: Json[Token]) -> Json[Token]:
    _bump(HANDLER)
    return Json(body^.take(), status=202)


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
    app.get["/created-addresses/{id}"](created_address)
    app.get["/teapot-addresses/{id}"](teapot_address)
    app.get["/measure-created/{id}"](measure_created)
    app.get["/refusing-created"](refusing_created)
    app.get["/explicit-addresses/{id}"](explicit_address)
    app.get["/unvalidated-addresses/{id}"](unvalidated_address)
    app.get["/status-after-failure"](status_set_after_failure)
    app.get["/media-type-after-failure"](media_type_after_failure)
    app.post["/return-body"](return_body)
    app.post["/tokens-created"](create_token)
    app.post["/staff-tokens"](staff_token, dir)
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
    assert_equal(r.text(), body)
    assert_equal(len(r.headers), 0)


def test_json_bodies_on_every_typed_shape() raises:
    # Body only and `Int` then body (path and query), stateless and
    # stateful, with both result policies.
    var app = json_app()
    for s in _shapes():
        var target = s[0]
        _reset()
        var r = _post(app, target, BODY)
        assert_equal(r.status, 200, target)
        assert_equal(r.text(), s[1], target)
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
    assert_equal(_post(app, "/users-text", ok).text(), "created A")
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
            assert_equal(r.text(), s[1])
            assert_equal(_count(HANDLER), 1)
        for v in materialize[REFUSED]():
            _reset()
            _assert_fixed(
                _post(app, target, BODY, v), 415, "Unsupported Media Type"
            )
            assert_equal(_count(HANDLER), 0, target + " " + v)
        # Missing, empty, and two fields (same or different values). A body
        # that reads "1" is never taken for the verdict.
        _reset()
        _assert_fixed(
            _post(app, target, BODY, ""), 415, "Unsupported Media Type"
        )
        _assert_fixed(
            _post(app, target, "1", ""), 415, "Unsupported Media Type"
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
    # The bare `TestClient.post` sends no Content-Type, so a JSON body route
    # answers 415; a test sends the field with `headers=` (M3-011).
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
        assert_equal(ok.text(), s[1])
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
    assert_equal(r.text(), '{"secret":"s3"}')
    assert_equal(r.headers.get("content-type").value(), "application/json")
    assert_equal(_count(HANDLER), 1)
    # Borrowed: the handler reads `body.value`.
    assert_equal(_post(app, "/peek", '{"secret":"s4"}').text(), "s4")
    # `take()` moves the value out of a `Json` the caller owns.
    var t = Json(Token("s5"))
    var token = t^.take()
    assert_equal(token.secret, "s5")


def test_raw_handler_decodes_with_from_body() raises:
    # A raw route runs no Content-Type or size step: the handler decodes
    # itself, and the parser's cap raises into its own error model.
    var app = json_app()
    var token = '{"secret":"r"}'
    assert_equal(_post(app, "/raw", token, "").text(), "r")
    assert_equal(_post(app, "/raw", token, "text/plain").text(), "r")
    var at_cap = _padded(token, _MAX_BODY_BYTES)
    var over = _padded(token, _MAX_BODY_BYTES + 1)
    assert_equal(_post(app, "/raw", at_cap).text(), "r")
    _assert_fixed(_post(app, "/raw", over), 500, "Internal Server Error")
    _assert_fixed(_post(app, "/raw", "{", ""), 500, "Internal Server Error")
    assert_equal(_post(app, "/raw-mapped", at_cap).text(), "r")
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


comptime SMALL = 4096
"""The chosen limit of the `/small` routes: above `BODY`, far below 1 MiB."""

comptime BIG = 2 * 1_048_576
"""The chosen limit of the `/big` routes: above `Json[T]`'s default."""


def raw_small(var req: Request) raises -> Response:
    # A raw handler's `Json[T, limit=n].from_body` raises above `n`.
    var body = Json[Token, limit=32].from_body(req.text())
    return Response.text(body.value.secret)


def short_limit_result() -> Json[Address, limit=4]:
    # `limit` means nothing on a result: the whole value is written.
    return Json[Address, limit=4](Address("Lisbon", 12345), status=201)


def same_type(var body: Json[Token, limit=_MAX_BODY_BYTES]) -> Json[Token]:
    # Builds only because `Json[T]` is `Json[T, limit=1048576]`.
    return body^


def limited_app() raises -> App:
    var dir = State(Directory(100))
    var app = App()
    app.post["/small/users"](l_create[SMALL])
    app.post["/small/users-text"](l_create_text[SMALL])
    app.post["/small/users/{id}"](l_update[SMALL])
    app.post["/small/users-text/{id}"](l_update_text[SMALL])
    app.post["/small/query?{id}"](l_update[SMALL])
    app.post["/small/staff"](l_staff_create[SMALL], dir)
    app.post["/small/staff-text"](l_staff_create_text[SMALL], dir)
    app.post["/small/staff/{id}"](l_staff_update[SMALL], dir)
    app.post["/small/staff-text/{id}"](l_staff_update_text[SMALL], dir)
    app.post["/small/staff-query?{id}"](l_staff_update[SMALL], dir)
    app.post["/small/carried/{id}"](l_carried[SMALL])
    app.post["/small/staff-carried"](l_staff_carried[SMALL], dir)
    app.put["/small/users"](l_create[SMALL])
    app.put["/small/users-text"](l_create_text[SMALL])
    app.put["/small/users/{id}"](l_update[SMALL])
    app.put["/small/users-text/{id}"](l_update_text[SMALL])
    app.put["/small/query?{id}"](l_update[SMALL])
    app.put["/small/staff"](l_staff_create[SMALL], dir)
    app.put["/small/staff-text"](l_staff_create_text[SMALL], dir)
    app.put["/small/staff/{id}"](l_staff_update[SMALL], dir)
    app.put["/small/staff-text/{id}"](l_staff_update_text[SMALL], dir)
    app.put["/small/staff-query?{id}"](l_staff_update[SMALL], dir)
    app.put["/small/carried/{id}"](l_carried[SMALL])
    app.put["/small/staff-carried"](l_staff_carried[SMALL], dir)
    app.patch["/small/users"](l_create[SMALL])
    app.patch["/small/users-text"](l_create_text[SMALL])
    app.patch["/small/users/{id}"](l_update[SMALL])
    app.patch["/small/users-text/{id}"](l_update_text[SMALL])
    app.patch["/small/query?{id}"](l_update[SMALL])
    app.patch["/small/staff"](l_staff_create[SMALL], dir)
    app.patch["/small/staff-text"](l_staff_create_text[SMALL], dir)
    app.patch["/small/staff/{id}"](l_staff_update[SMALL], dir)
    app.patch["/small/staff-text/{id}"](l_staff_update_text[SMALL], dir)
    app.patch["/small/staff-query?{id}"](l_staff_update[SMALL], dir)
    app.patch["/small/carried/{id}"](l_carried[SMALL])
    app.patch["/small/staff-carried"](l_staff_carried[SMALL], dir)
    app.post["/big/users"](l_create[BIG])
    app.post["/big/users-text"](l_create_text[BIG])
    app.post["/big/users/{id}"](l_update[BIG])
    app.post["/big/users-text/{id}"](l_update_text[BIG])
    app.post["/big/query?{id}"](l_update[BIG])
    app.post["/big/staff"](l_staff_create[BIG], dir)
    app.post["/big/staff-text"](l_staff_create_text[BIG], dir)
    app.post["/big/staff/{id}"](l_staff_update[BIG], dir)
    app.post["/big/staff-text/{id}"](l_staff_update_text[BIG], dir)
    app.post["/big/staff-query?{id}"](l_staff_update[BIG], dir)
    app.post["/big/carried/{id}"](l_carried[BIG])
    app.post["/big/staff-carried"](l_staff_carried[BIG], dir)
    app.post["/widest/users"](l_create[4_294_967_295])
    app.post["/raw-small"](raw_small)
    app.get["/short-limit"](short_limit_result)
    app.post["/same-type"](same_type)
    return app^


def _limited_shapes() -> List[Tuple[String, String]]:
    """`_shapes()` and the two carried routes, without their prefix."""
    var s = _shapes()
    s.append((String("/carried/9"), "updated 9 " + NAME))
    s.append((String("/staff-carried"), _user_json(100)))
    return s^


def _handle(
    app: App,
    method: String,
    target: String,
    var body: List[UInt8],
    content_type: String = "application/json",
) raises -> Response:
    var h = Headers()
    if content_type.byte_length() > 0:
        h.add("Content-Type", content_type)
    return app.handle(Request(method, target, body^, h^))


def _bytes(text: String) -> List[UInt8]:
    return List(text.as_bytes())


def test_a_chosen_limit_on_every_json_body_shape_and_method() raises:
    # `Json[T, limit=n]`: exactly `n` bytes are parsed; one byte more is 413
    # before parsing and the handler, after the route value and the 415
    # step, bare and carried, with and without state, on every method.
    var app = limited_app()
    var at = _bytes(_padded(BODY, SMALL))
    var over = _bytes(_padded(BODY, SMALL + 1))
    var bad_at = _bytes(_padded("{", SMALL))
    var bad_over = _bytes(_padded("{", SMALL + 1))
    for m in ["POST", "PUT", "PATCH"]:
        for s in _limited_shapes():
            var target = "/small" + s[0]
            var what = String(m, " ", target)
            _reset()
            var ok = _handle(app, m, target, at.copy())
            assert_equal(ok.status, 200, what)
            assert_equal(ok.text(), s[1], what)
            assert_equal(_count(HANDLER), 1, what)
            _reset()
            _assert_fixed(
                _handle(app, m, target, over.copy()), 413, "Content Too Large"
            )
            _assert_fixed(
                _handle(app, m, target, over.copy(), "text/plain"),
                415,
                "Unsupported Media Type",
            )
            _assert_fixed(
                _handle(app, m, target, bad_at.copy()), 400, "Bad Request"
            )
            _assert_fixed(
                _handle(app, m, target, bad_over.copy()),
                413,
                "Content Too Large",
            )
            assert_equal(_count(HANDLER), 0, what)
        for target in [
            "/small/users/x",
            "/small/staff-text/x",
            "/small/query?id=x",
            "/small/carried/x",
        ]:
            _assert_fixed(
                _handle(app, m, target, over.copy(), "text/plain"),
                400,
                "Bad Request",
            )
        assert_equal(_count(HANDLER), 0)


def test_a_limit_above_the_default() raises:
    var app = limited_app()
    var over_default = _bytes(_padded(BODY, _MAX_BODY_BYTES + 1))
    var at = _bytes(_padded(BODY, BIG))
    var over = _bytes(_padded(BODY, BIG + 1))
    for s in _limited_shapes():
        var target = "/big" + s[0]
        _reset()
        assert_equal(
            _handle(app, "POST", target, over_default.copy()).text(),
            s[1],
            target,
        )
        assert_equal(_handle(app, "POST", target, at.copy()).text(), s[1])
        _assert_fixed(
            _handle(app, "POST", target, over.copy()), 413, "Content Too Large"
        )
        assert_equal(_count(HANDLER), 2, target)
    # The widest limit the parser addresses, 2^32 - 1.
    assert_equal(
        _handle(app, "POST", "/widest/users", _bytes(BODY)).text(),
        _user_json(1),
    )


def test_a_json_limit_is_413_before_the_utf8_read() raises:
    # A byte that is not UTF-8 inside the name: within the limit it is the
    # UTF-8 read's 400; one byte over the limit, 413.
    var app = limited_app()
    for size in [SMALL, SMALL + 1]:
        var body = _bytes(_padded(BODY, size))
        body[10] = 0xFF
        _reset()
        _assert_fixed(
            _handle(app, "PUT", "/small/users", body^),
            400 if size == SMALL else 413,
            "Bad Request" if size == SMALL else "Content Too Large",
        )
        assert_equal(_count(HANDLER), 0)


def test_a_json_limit_in_a_raw_handler_and_on_a_result() raises:
    var app = limited_app()
    var token = '{"secret":"r"}'
    assert_equal(_post(app, "/raw-small", _padded(token, 32)).text(), "r")
    _assert_fixed(
        _post(app, "/raw-small", _padded(token, 33)),
        500,
        "Internal Server Error",
    )
    var raised = False
    try:
        _ = Json[Token, limit=32].from_body(_padded(token, 33))
    except e:
        raised = True
        assert_equal(String(e), "JSON body too large")
    assert_true(raised)
    var r = TestClient(app).get("/short-limit")
    assert_equal(r.status, 201)
    assert_equal(r.text(), '{"city":"Lisbon","zip":12345}')


def test_a_json_limit_is_read_at_compile_time() raises:
    assert_equal(Json[CreateUser].max_bytes, _MAX_BODY_BYTES)
    assert_equal(Json[CreateUser, limit=32].max_bytes, 32)
    assert_equal(Json[CreateUser, limit=BIG].max_bytes, BIG)
    assert_equal(
        Json[CreateUser, limit=_MAX_BODY_BYTES].max_bytes,
        Json[CreateUser].max_bytes,
    )
    var app = limited_app()
    assert_equal(
        _post(app, "/same-type", '{"secret":"s"}').text(), '{"secret":"s"}'
    )


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
        assert_equal(r.text(), pair[1])
        assert_equal(len(r.headers), 1)
        assert_equal(r.headers.name(0), "Content-Type")
        assert_equal(r.headers.value(0), "application/json")
    var p = client.post("/note-address", 'Ri"ga')
    assert_equal(p.status, 200)
    assert_equal(p.text(), '{"city":"Ri\\"ga","zip":1}')
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
    assert_equal(e.text(), "teapot")
    assert_equal(_count(ERROR_CONVERSIONS), 1)
    _reset()
    assert_equal(client.get("/measure/2").text(), '{"value":1.5}')


def test_explicit_response_override() raises:
    var app = json_app()
    var r = TestClient(app).get("/created")
    assert_equal(r.status, 201)
    assert_equal(r.text(), '{"city":"Rome","zip":7}')
    assert_equal(len(r.headers), 1)
    assert_equal(
        r.headers.get("content-type").value(), "application/problem+json"
    )


def _assert_json(r: Response, status: Int, body: String) raises:
    assert_equal(r.status, status)
    assert_equal(r.text(), body)
    assert_equal(len(r.headers), 1)
    assert_equal(r.headers.name(0), "Content-Type")
    assert_equal(r.headers.value(0), "application/json")


def test_json_result_status() raises:
    # `Json(value)` is 200; `Json(value, status=)` answers that status with
    # the same body and the one `Content-Type` field, 2xx or not.
    var app = json_app()
    var client = TestClient(app)
    var plain = client.get("/addresses/7")
    _assert_json(plain, 200, '{"city":"Paris","zip":7}')
    _assert_json(client.get("/created-addresses/7"), 201, plain.text())
    _assert_json(client.get("/teapot-addresses/7"), 418, plain.text())
    _assert_json(client.get("/unvalidated-addresses/7"), 999, plain.text())
    _assert_json(client.get("/explicit-addresses/7"), 200, plain.text())
    _assert_json(client.get("/measure-created/2"), 201, '{"value":1.5}')
    # `Json[T].to_response()` called directly applies it too.
    _assert_json(Json(Address("Paris", 7)).to_response(), 200, plain.text())
    _assert_json(
        Json(Address("Paris", 7), status=201).to_response(), 201, plain.text()
    )


def test_json_result_status_on_json_body_routes() raises:
    # A JSON body in, a chosen status out: the request steps are unchanged
    # (415 before the handler), and the stateful form answers its own status.
    var app = json_app()
    _reset()
    _assert_json(
        _post(app, "/tokens-created", '{"secret":"s"}'), 201, '{"secret":"s"}'
    )
    _assert_json(
        _post(app, "/staff-tokens", '{"secret":"t"}'), 202, '{"secret":"t"}'
    )
    assert_equal(_count(HANDLER), 2)
    _assert_json(
        _post(app, "/return-body", '{"secret":"u"}'), 200, '{"secret":"u"}'
    )
    _reset()
    _assert_fixed(
        _post(app, "/tokens-created", '{"secret":"s"}', ""),
        415,
        "Unsupported Media Type",
    )
    _assert_fixed(_post(app, "/staff-tokens", "{"), 400, "Bad Request")
    assert_equal(_count(HANDLER), 0)


def test_serialization_failure_ignores_the_chosen_status() raises:
    # The status applies to a successful write only: a non-finite number or
    # a raising `write_json` is the fixed 500 without a Content-Type.
    var app = json_app()
    var client = TestClient(app)
    _assert_fixed(
        client.get("/measure-created/0"), 500, "Internal Server Error"
    )
    _assert_fixed(client.get("/refusing-created"), 500, "Internal Server Error")
    # A status set after the conversion overwrites the 500
    # (docs/reference/responses.md).
    _assert_fixed(
        client.get("/status-after-failure"), 201, "Internal Server Error"
    )
    # So does a field set there: the 500 carries it.
    var m = client.get("/media-type-after-failure")
    assert_equal(m.status, 500)
    assert_equal(m.text(), "Internal Server Error")
    assert_equal(len(m.headers), 1)
    assert_equal(
        m.headers.get("content-type").value(), "application/problem+json"
    )


def test_head_on_a_json_result_with_a_status() raises:
    # In memory, `HEAD` answers what `GET` answers, chosen status included;
    # the backend keeps the content off the wire (adapters/flare).
    var app = json_app()
    var get = app.handle(Request("GET", "/created-addresses/7"))
    var head = app.handle(Request("HEAD", "/created-addresses/7"))
    _assert_json(head, 201, get.text())


def test_text_results_keep_no_default_fields() raises:
    var app = json_app()
    var client = TestClient(app)
    for target in ["/hello", "/health"]:
        var r = client.get(target)
        assert_equal(r.status, 200)
        assert_equal(len(r.headers), 0, target)
    assert_equal(len(Response.text("x").headers), 0)
    assert_equal(len(_post(app, "/users-text", BODY).headers), 0)


def test_non_json_bodies_are_unchanged_and_capped_at_one_mib() raises:
    # An application `FromBody` route requires no Content-Type, receives the
    # body unchanged, keeps its 400, and its type, declaring no
    # `max_bytes`, is limited to 1 MiB (M3-089).
    var app = json_app()
    var client = TestClient(app)
    var at = String("x") * _MAX_BODY_BYTES
    var over = String("x") * (_MAX_BODY_BYTES + 1)
    var r = client.post("/notes", at)
    assert_equal(r.status, 200)
    assert_equal(r.body.byte_length(), _MAX_BODY_BYTES)
    _assert_fixed(client.post("/notes", over), 413, "Content Too Large")
    assert_equal(client.post("/notes", "{").text(), "{")
    assert_equal(_post(app, "/notes", "hi", "text/plain").text(), "hi")
    assert_equal(_post(app, "/notes", "hi").text(), "hi")
    assert_equal(client.post("/notes/4", at).text(), "4:1048576")
    _assert_fixed(client.post("/notes/4", over), 413, "Content Too Large")
    assert_equal(client.post("/notes/x", over).status, 400)
    assert_equal(client.post("/staff-notes", at).text(), "100:1048576")
    _assert_fixed(client.post("/staff-notes", over), 413, "Content Too Large")
    _assert_fixed(client.post("/notes", "fail"), 400, "Bad Request")
    _assert_fixed(client.post("/staff-notes", "fail"), 400, "Bad Request")


def test_number_limits() raises:
    # `float()` raises only past the largest finite double (400 through a
    # body); below the smallest it is a signed zero. `int()` is exact.
    for s in ["1e400", "-1e400", "1.7976931348623159e308", "1e999999999999"]:
        var raised = False
        try:
            _ = _parse_json(s).float()
        except:
            raised = True
        assert_true(raised, s)
    assert_equal(_bits(_parse_json("1e-400").float()), UInt64(0))
    assert_equal(
        _bits(_parse_json("-1e-400").float()), UInt64(0x8000000000000000)
    )
    assert_equal(_bits(_parse_json("-0").float()), UInt64(0x8000000000000000))
    assert_equal(_bits(_parse_json("0e999999999999").float()), UInt64(0))
    # The exact halfway point past the largest double rounds to 2^1024 (even),
    # so it raises; one unit less is the largest double.
    var raised = False
    try:
        _ = _parse_json(
            _halfway(_HALF_PAST_MAX_DIGITS, _HALF_PAST_MAX_EXPONENT)
        ).float()
    except:
        raised = True
    assert_true(raised, "halfway past the largest double")
    _assert_reads(
        _below(_HALF_PAST_MAX_DIGITS, _HALF_PAST_MAX_EXPONENT),
        0x7FEFFFFFFFFFFFFF,
    )
    assert_equal(_parse_json("9223372036854775807").int(), Int.MAX)
    assert_equal(_parse_json("-9223372036854775808").int(), Int.MIN)


def _bits(x: Float64) -> UInt64:
    return bitcast[DType.uint64](x)


def _written(value: Float64) raises -> String:
    var w = JsonWriter()
    w.float(value)
    return w^._finish()


# Exact decimal halfway points between neighbouring doubles (Python's
# `Decimal`), split for width: between the largest subnormal and the
# smallest normal (768 significant digits, the most any has), between the
# two largest subnormals, between zero and the smallest subnormal (2^-1075),
# and between the largest double and 2^1024.
comptime _HALF_TO_NORMAL_DIGITS = (
    "2.22507385850720113605740979670913197593481954635164564802342610"
    "9724822222021076945516529523908135087914149158913039621106870086"
    "4386945946455276572074078206217433799881410632673292535522868813"
    "7214901298112245145188984905722230728525513315575501591439747639"
    "7983411801999323962548289017107081850690630666655994938275772572"
    "0157630626906633326475653000092458883164330377797918696120494973"
    "9037782970490505108060994073026293712895895000358379996720725430"
    "4360284078895771796150945516748243471030702609144621572289880258"
    "1825451803257070188608721131280795122334262883686223215037756666"
    "2250398253433597456888442390026549819838548794829220689472168983"
    "1099698365846814022854243330660339850886445804001034933970427567"
    "1864433837704860378616227717385456230658746790140867233276367187"
    "5"
)
comptime _HALF_TO_NORMAL_EXPONENT = "e-308"

comptime _HALF_SUBNORMAL_DIGITS = (
    "2.22507385850720064199176395546258779936602667813027328296362349"
    "5400057796435394444841022253699383222614312797277047241310305390"
    "9929768637188709468514680242229685839773591851410285403619754768"
    "4430319581327346934820113042116530855453208314936760676083249201"
    "0670938404726154347408257301721683776564392101064823911617215885"
    "2475760231303527077156200284177534329871275812353907421319197873"
    "9083589771549597066404661620550578925994422322342444472859570416"
    "9556757585423752417124134805999073137808018133811049489046686648"
    "9442558344889010082597214961471042043991985565356975310055231935"
    "4486638980954850896040660352681852824502078615102443513620912377"
    "5979785215357703877750457056843614755302706830641135567489433450"
    "7658731200614581135848683152156368691976240370422601699829101562"
    "5"
)
comptime _HALF_SUBNORMAL_EXPONENT = "e-308"

comptime _HALF_TO_ZERO_DIGITS = (
    "2.47032822920623272088284396434110686182529901307162382212792841"
    "2503377536351043759326499181808179961898982823477228588654633283"
    "5517796989819938739800539093906315035659515570226392290858392449"
    "1051844359318028499365361525003193704576782492193656236698636584"
    "8075700158576926990370631192827955855133292783433840935197801553"
    "1246597263579574622766465272827220056374006485499977096599470454"
    "0208281662262378573934507363390079677619305775067401763246736009"
    "6895134053553745851666113422376667860416215968046191446729184030"
    "0530057530849048765391711386591646239524912623653881879636239373"
    "2804238910186723484976682350898633885879256283027559956575244555"
    "0725518931369083625477918694866799496832404970582102851318545139"
    "6213837722826145437693412532098591327667236328125"
)
comptime _HALF_TO_ZERO_EXPONENT = "e-324"

comptime _HALF_PAST_MAX_DIGITS = (
    "1.79769313486231580793728971405303415079934132710037826936173778"
    "9804449682927647509466490179775872070963302864166928879109465555"
    "4785194040263065748867150582068190890200070838367627385484581771"
    "1531764475730270069855571366959622842914819860834936475292719074"
    "168444365510704342711559699508093042880177904174497792"
)
comptime _HALF_PAST_MAX_EXPONENT = "e+308"


def _halfway(digits: String, exponent: String) -> String:
    return digits + exponent


def _below(digits: String, exponent: String) -> String:
    """One unit less in the last digit, which is never 0."""
    var n = digits.byte_length()
    var last = chr(ord(String(digits[byte = n - 1 : n])) - 1)
    return String(digits[byte = 0 : n - 1]) + last + exponent


def _past_kept(digits: String, exponent: String) -> String:
    """The halfway point plus a 1 past the 800 significant digits kept."""
    return digits + "0" * (805 - digits.byte_length()) + "1" + exponent


def _assert_reads(text: String, expected: UInt64) raises:
    assert_equal(_bits(_parse_json(text).float()), expected, text)


def _long_literal(zeros: Int, exponent: String) -> String:
    """`1`, `zeros` zeros, then `exponent`."""
    var b = List[UInt8](length=zeros + 1, fill=UInt8(0x30))
    b[0] = 0x31
    b.extend(Span(exponent.as_bytes()))
    return String(unsafe_from_utf8=b^)


def test_an_exponent_past_a_billion_reads_within_the_widest_limit() raises:
    # 1,000,000,014 bytes, within `limit=4_294_967_295`: 10^(10^9 - 10^10)
    # is 0.0. Read only up to 10^9 (a cut sized for 1 MiB), the exponent
    # would be cancelled by the digits and the result 1.0. About 2 GB.
    var t = _long_literal(1_000_000_000, "e-10000000000")
    assert_equal(t.byte_length(), 1_000_000_014)
    assert_equal(_bits(_to_float64(t)), UInt64(0))


def test_float_is_correctly_rounded() raises:
    # Each literal reads as the nearest double, ties to even; the bits are
    # Python's `float()`. The first seven came back 1 ulp off or raised
    # through Mojo 1.1.0's `atof`.
    _assert_reads("-2.7546748226290886e+20", 0xC42DDDC22F41F7CD)
    _assert_reads("2.3786116091973052e+20", 0x4429C9F9333A6521)
    _assert_reads("123456789012345678", 0x437B69B4BA630F35)
    _assert_reads("123456789012345678901234", 0x44BA249B1F10A06D)
    _assert_reads("1.2345678901234567890123", 0x3FF3C0CA428C59FB)
    _assert_reads("100000000000000000000000", 0x44B52D02C7E14AF6)
    _assert_reads("0.000000000000000000000000000001", 0x39B4484BFEEBC2A0)
    _assert_reads("0.1", 0x3FB999999999999A)
    _assert_reads("1e23", 0x44B52D02C7E14AF6)
    _assert_reads("9007199254740993", 0x4340000000000000)
    _assert_reads("8.98846567431158e307", 0x7FE0000000000000)
    _assert_reads("1.7976931348623158e308", 0x7FEFFFFFFFFFFFFF)
    _assert_reads("2.2250738585072011e-308", 0x000FFFFFFFFFFFFF)
    _assert_reads("2.2250738585072012e-308", 0x0010000000000000)
    _assert_reads("4.9406564584124654e-324", 0x0000000000000001)
    _assert_reads("2.4703282292062328e-324", 0x0000000000000001)
    _assert_reads("2.4703282292062327e-324", 0)
    _assert_reads(String("1") + "0" * 308, 0x7FE1CCF385EBC8A0)
    _assert_reads(String("0.") + "0" * 5000 + "1", 0)
    # Exact ties, 1 + 2^-53 and 1 + 3 * 2^-53, go to the even neighbour;
    # a nonzero digit past the 800 kept ones still breaks a tie upward.
    var tie = String("1.00000000000000011102230246251565404236316680908203125")
    _assert_reads(tie, 0x3FF0000000000000)
    _assert_reads(
        "1.00000000000000033306690738754696212708950042724609375",
        0x3FF0000000000002,
    )
    _assert_reads(tie + "0" * 900, 0x3FF0000000000000)
    _assert_reads(tie + "0" * 900 + "1", 0x3FF0000000000001)
    # The 768-digit halfway point between the largest subnormal and the
    # smallest normal ties to the even one, the normal; one unit less is the
    # subnormal. Between two subnormals the tie goes down to the even one,
    # and a 1 past the kept digits breaks it upward. 2^-1075 ties to zero.
    _assert_reads(
        _halfway(_HALF_TO_NORMAL_DIGITS, _HALF_TO_NORMAL_EXPONENT),
        0x0010000000000000,
    )
    _assert_reads(
        _below(_HALF_TO_NORMAL_DIGITS, _HALF_TO_NORMAL_EXPONENT),
        0x000FFFFFFFFFFFFF,
    )
    _assert_reads(
        _halfway(_HALF_SUBNORMAL_DIGITS, _HALF_SUBNORMAL_EXPONENT),
        0x000FFFFFFFFFFFFE,
    )
    _assert_reads(
        _past_kept(_HALF_SUBNORMAL_DIGITS, _HALF_SUBNORMAL_EXPONENT),
        0x000FFFFFFFFFFFFF,
    )
    _assert_reads(_halfway(_HALF_TO_ZERO_DIGITS, _HALF_TO_ZERO_EXPONENT), 0)
    _assert_reads(
        _past_kept(_HALF_TO_ZERO_DIGITS, _HALF_TO_ZERO_EXPONENT),
        0x0000000000000001,
    )
    # Long, signed and scaled down.
    _assert_reads(String("-") + tie + "0" * 900 + "1e-2", 0xBF847AE147AE147C)


def test_float_writer_gap_on_mojo_1_1_0() raises:
    # Pinned Mojo 1.1.0 behavior: the writer uses `String(Float64)`, whose
    # text does not always read back to the same double (Python writes
    # -3.7609587960547416e+16). A fix in the toolchain turns this red:
    # revisit (docs/history/architecture-decisions.md, "JSON codec decision
    # (M3-008)").
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
