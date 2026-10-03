# M3-008 JSON codec decision spike, application side (library side:
# tests/json_spike.mojo). Application types conform to `FromJson`/`ToJson`
# here; `Json[T]` reaches the production `App` through the existing
# `FromBody`/`ToResponse` overloads, with no App change. The Content-Type
# step and its order are measured on the spike's mirror of the body adapters
# (`model_post`, `model_post_int`), since production does not have it yet.
# Decision: docs/ARCHITECTURE.md, "JSON codec decision (M3-008)".

from std.collections import Optional
from std.os import getenv, setenv, unsetenv
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from muntin import (
    App,
    FromBody,
    Headers,
    Request,
    Response,
    State,
    ToErrorResponse,
    ToResponse,
)
from muntin.testing import TestClient
from json_spike import (
    FromJson,
    Json,
    JsonValue,
    JsonWriter,
    MAX_DEPTH,
    ToJson,
    json_content_type,
    json_response,
    model_post,
    model_post_int,
    parse_json,
)

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


def create_user(var body: Json[CreateUser]) -> Json[User]:
    _bump(HANDLER)
    return Json(_user(1, body^.take()))


def update_user(id: Int, var body: Json[CreateUser]) -> Json[User]:
    _bump(HANDLER)
    return Json(_user(id, body^.take()))


def get_user(id: Int) -> Json[Address]:
    return Json(Address("Paris", id))


@fieldwise_init
struct Directory(Movable):
    var city: String


def get_staff(dir: State[Directory], id: Int) -> Json[Address]:
    return Json(Address(dir[].city, id))


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
    return Json(body^.take())


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


def unbalanced() -> Json[Unbalanced]:
    return Json(Unbalanced())


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
    var app = App()
    app.post["/users"](create_user)
    app.post["/users/{id}"](update_user)
    app.get["/users/{id}"](get_user)
    app.get["/staff/{id}"](get_staff, State(Directory("Oslo")))
    app.post["/tokens"](echo_token)
    app.get["/measure/{id}"](measure)
    app.get["/unbalanced"](unbalanced)
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
comptime USER = (
    '{"id":1,"name":"Ada \\"L\\"é😀","admin":true,"score":-150.0,'
    + '"tags":["a","b\\n"],"nickname":null,"home":{"city":"X","zip":1},'
    + '"past":[{"city":"Y","zip":2}]}'
)


def _json_headers(value: String = "application/json") raises -> Headers:
    var h = Headers()
    h.add("Content-Type", value)
    return h^


def test_production_app_accepts_json_through_existing_overloads() raises:
    # No App overload is added: `Json[T]` is a `FromBody` and a
    # `ToResponse`, so `def(B)`, `def(Int, B)`, `def(Int) -> R` and the
    # stateful `def(State[S], Int) -> R` take it as they are.
    var app = json_app()
    var client = TestClient(app)
    _reset()
    var r = client.post("/users", BODY)
    assert_equal(r.status, 200)
    assert_equal(r.body, USER)
    assert_equal(len(r.headers), 1)
    assert_equal(r.headers.name(0), "Content-Type")
    assert_equal(r.headers.value(0), "application/json")
    var u = client.post("/users/9", BODY)
    assert_equal(u.status, 200)
    assert_true(u.body.startswith('{"id":9,'))
    assert_equal(client.get("/users/5").body, '{"city":"Paris","zip":5}')
    assert_equal(client.get("/staff/3").body, '{"city":"Oslo","zip":3}')
    assert_equal(_count(HANDLER), 2)


def test_representative_round_trip_kinds() raises:
    var v = parse_json(BODY)
    var c = CreateUser.from_json(v)
    assert_equal(c.name, 'Ada "L"é😀')
    assert_equal(c.age, 36)
    assert_true(c.admin)
    assert_equal(c.score, -150.0)
    assert_equal(len(c.tags), 2)
    assert_equal(c.tags[1], "b\n")
    assert_false(Bool(c.nickname))
    assert_equal(c.home.zip, 1)
    assert_equal(c.past[0].city, "Y")
    # Absent optional member and present null are told apart.
    var absent = parse_json('{"a":1}')
    assert_false(Bool(absent.get("nickname")))
    assert_true(parse_json('{"n":null}')["n"].is_null())
    # Top-level scalars and arrays are JSON texts too (RFC 8259).
    assert_equal(parse_json(" 42 ").int(), 42)
    assert_equal(parse_json("[true,false,null]")[1].bool(), False)
    assert_equal(parse_json('"x"').string(), "x")
    assert_equal(parse_json("-0").int(), 0)
    assert_equal(parse_json("0.5e-1").float(), 0.05)


def test_malformed_json_is_400_before_the_handler() raises:
    var bad = List[String]()
    for s in [
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
    ]:
        bad.append(s)
    var app = json_app()
    var client = TestClient(app)
    for s in bad:
        var raised = False
        try:
            _ = parse_json(s)
        except:
            raised = True
        assert_true(raised, "parsed: " + s)
        _reset()
        var r = client.post("/users", s)
        assert_equal(r.status, 400, s)
        assert_equal(r.body, "Bad Request")
        assert_equal(len(r.headers), 0)
        assert_equal(_count(HANDLER), 0)


def test_field_errors_are_400_and_extra_members_are_ignored() raises:
    var app = json_app()
    var client = TestClient(app)
    for s in [
        '{"name":"A"}',
        '{"name":1,"age":1,"admin":true,"score":1,"tags":[],"home":{"city":"","zip":0},"past":[]}',
        '{"name":"A","age":1.5,"admin":true,"score":1,"tags":[],"home":{"city":"","zip":0},"past":[]}',
        '{"name":"A","age":1e2,"admin":true,"score":1,"tags":[],"home":{"city":"","zip":0},"past":[]}',
        '{"name":"A","age":99999999999999999999,"admin":true,"score":1,"tags":[],"home":{"city":"","zip":0},"past":[]}',
        '{"name":"A","age":1,"admin":"yes","score":1,"tags":[],"home":{"city":"","zip":0},"past":[]}',
        '{"name":"A","age":1,"admin":true,"score":1,"tags":[1],"home":{"city":"","zip":0},"past":[]}',
        '{"name":"A","age":1,"admin":true,"score":1,"tags":[],"home":[],"past":[]}',
        "[]",
        "null",
    ]:
        _reset()
        assert_equal(client.post("/users", s).status, 400, s)
        assert_equal(_count(HANDLER), 0)
    _reset()
    var ok = '{"name":"A","age":1,"admin":false,"score":1,"tags":[],"home":{"city":"","zip":0},"past":[],"zzz":{"deep":[1,2,3]}}'
    assert_equal(client.post("/users", ok).status, 200)
    assert_equal(_count(HANDLER), 1)


def test_nesting_cap() raises:
    var ok = String()
    var too_deep = String()
    for _ in range(MAX_DEPTH):
        ok += "["
    for _ in range(MAX_DEPTH):
        ok += "]"
    for _ in range(MAX_DEPTH + 1):
        too_deep += "["
    for _ in range(MAX_DEPTH + 1):
        too_deep += "]"
    _ = parse_json(ok)
    var raised = False
    try:
        _ = parse_json(too_deep)
    except:
        raised = True
    assert_true(raised)


def test_number_limits_on_mojo_1_1_0() raises:
    # `float()` rejects overflow, and Mojo 1.1.0 `atof` rejects literals with
    # more significant digits than it supports: both raise (400 through a
    # body). A pinned gap: valid JSON numbers a future `atof` may accept.
    for s in [
        "1e400",
        "-1e400",
        "123456789012345678901234",
        "1.2345678901234567890123",
    ]:
        var raised = False
        try:
            _ = parse_json(s).float()
        except:
            raised = True
        assert_true(raised, s)
    assert_equal(parse_json("1e-400").float(), 0.0)
    assert_equal(parse_json("9223372036854775807").int(), Int.MAX)


def test_writer_escapes_and_structure() raises:
    var w = JsonWriter()
    w.begin_object()
    w.name('q"\\')
    w.string("a\x01\x1f\t\r\n\x7f é")
    w.name("f")
    w.float(1e16)
    w.name("n")
    w.null()
    w.end_object()
    assert_equal(
        w^.finish(),
        '{"q\\"\\\\":"a\\u0001\\u001f\\t\\r\\n\x7f é","f":1e+16,"n":null}',
    )
    # Structural misuse and non-finite numbers raise.
    var cases = List[Int]()
    for i in range(7):
        cases.append(i)
    for i in cases:
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
                _ = out^.finish()
                out = JsonWriter()
                _ = out^.finish()
            else:
                _ = out^.finish()
                out = JsonWriter()
                _ = out^.finish()
        except:
            raised = True
        assert_true(raised, String(i))


def test_serialization_failure_is_not_a_handler_error() raises:
    # The handler returns; the writer raises (NaN, infinity) or is left
    # unbalanced. The answer is the fixed 500 without a Content-Type, and the
    # handler's `ToErrorResponse` is not called. A raised `AppError` still
    # takes the handler-error path (418).
    var app = json_app()
    var client = TestClient(app)
    for target in ["/measure/0", "/measure/1", "/unbalanced"]:
        _reset()
        var r = client.get(target)
        assert_equal(r.status, 500, target)
        assert_equal(r.body, "Internal Server Error")
        assert_equal(len(r.headers), 0)
        assert_equal(_count(ERROR_CONVERSIONS), 0)
    _reset()
    _ = setenv(FAIL, "1")
    var e = client.get("/measure/2")
    assert_equal(e.status, 418)
    assert_equal(_count(ERROR_CONVERSIONS), 1)
    _reset()
    assert_equal(client.get("/measure/2").body, '{"value":1.5}')


def test_move_only_body_and_result() raises:
    var app = json_app()
    var client = TestClient(app)
    var r = client.post("/tokens", '{"secret":"s3"}')
    assert_equal(r.status, 200)
    assert_equal(r.body, '{"secret":"s3"}')


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


def test_request_content_type_rule() raises:
    for v in [
        "application/json",
        "Application/JSON",
        "application/json; charset=utf-8",
        "application/json;charset=UTF-8",
        "application/json ; charset=utf-8",
        "application/json; charset=latin1",
    ]:
        assert_true(json_content_type(_json_headers(v)), v)
    for v in [
        "text/plain",
        "text/plain; charset=utf-8",
        "application/problem+json",
        "application/jsonx",
        "application/x-www-form-urlencoded",
        "multipart/form-data; boundary=x",
        "application",
        "",
    ]:
        assert_false(json_content_type(_json_headers(v)), v)
    assert_false(json_content_type(Headers()))
    var two = Headers()
    two.add("Content-Type", "application/json")
    two.add("content-type", "application/json")
    assert_false(json_content_type(two))


@fieldwise_init
struct Note(FromBody):
    var text: String

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def note(body: Note) -> Response:
    return Response.text(body.text)


def create_user_model(var body: Json[CreateUser]) -> Json[User]:
    _bump(HANDLER)
    return Json(_user(1, body^.take()))


def update_user_model(id: Int, var body: Json[CreateUser]) -> Json[User]:
    _bump(HANDLER)
    return Json(_user(id, body^.take()))


def test_selected_order_on_the_adapter_mirror() raises:
    # 415 when the Content-Type is not JSON, before the body is parsed (a
    # malformed body with a wrong type is 415, not 400); 400 for a bad body
    # with the right type; a route value converts first (400 before 415).
    _reset()
    assert_equal(
        model_post(create_user_model, Request("POST", "/users", BODY)).status,
        415,
    )
    assert_equal(
        model_post(
            create_user_model,
            Request("POST", "/users", "{", _json_headers("text/plain")),
        ).body,
        "Unsupported Media Type",
    )
    assert_equal(
        model_post(
            create_user_model, Request("POST", "/users", "{", _json_headers())
        ).status,
        400,
    )
    assert_equal(_count(HANDLER), 0)
    var ok = model_post(
        create_user_model,
        Request(
            "POST",
            "/users",
            BODY,
            _json_headers("application/json; charset=utf-8"),
        ),
    )
    assert_equal(ok.status, 200)
    assert_equal(ok.body, USER)
    assert_equal(_count(HANDLER), 1)
    assert_equal(
        model_post_int(
            update_user_model, "abc", Request("POST", "/users/abc", "{")
        ).status,
        400,
    )
    assert_equal(
        model_post_int(
            update_user_model, "7", Request("POST", "/users/7", "{")
        ).status,
        415,
    )
    assert_equal(
        model_post_int(
            update_user_model,
            "7",
            Request("POST", "/users/7", BODY, _json_headers()),
        ).status,
        200,
    )
    # A non-JSON body type is unchanged: no Content-Type is required.
    assert_equal(model_post(note, Request("POST", "/n", "hi")).body, "hi")


def test_json_value_copies_share_the_document() raises:
    # Allocation: one tape per parse; a sub-value copies one reference, not
    # the tape; string accessors return copies.
    var v = parse_json('{"a":{"b":[1,2]}}')
    assert_equal(v._doc.count(), 1)
    var a = v["a"]
    var b = a["b"]
    assert_equal(v._doc.count(), 3)
    assert_equal(b[1].int(), 2)
    _ = a^
    _ = b^
    assert_equal(v._doc.count(), 1)


# Candidate C (rejected): a helper-only API. Same bytes as the wrapper, but
# the handler returns `Response`, must raise, and a serialization failure
# takes the handler-error path.


def created_with_helper() raises -> Response:
    return json_response(Address("Rome", 7), status=201)


def measure_with_helper() raises AppError -> Response:
    try:
        return json_response(Measurement(Float64(0) / Float64(0)))
    except:
        raise AppError()


def test_candidate_c_helper_moves_serialization_failure_into_the_handler() raises:
    var app = App()
    app.get["/created"](created_with_helper)
    app.get["/nan"](measure_with_helper)
    var client = TestClient(app)
    var helper = client.get("/created")
    var wrapper = Json(Address("Rome", 7)).to_response()
    wrapper.status = 201
    assert_equal(helper.status, wrapper.status)
    assert_equal(helper.body, wrapper.body)
    assert_equal(
        helper.headers.get("content-type").value(),
        wrapper.headers.get("content-type").value(),
    )
    _reset()
    var nan = client.get("/nan")
    assert_equal(nan.status, 418)
    assert_equal(_count(ERROR_CONVERSIONS), 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
