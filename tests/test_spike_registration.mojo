# M3-014 registration-structure spike, application side: the selected
# candidate's mechanism (tests/registration_spike.mojo) on Mojo 1.1.0.
# One overload per request-slot arity selects every handler shape production
# registers today, with each parameter's kind and the result policy decided
# at compile time; new slot types (a String route value, Headers) need no
# new overload; extraction failures answer before the handler and the error
# model is production's. Decision: docs/ARCHITECTURE.md, "Registration
# structure decision (M3-014)". Must-not-compile counterparts:
# tests/registration_fail; the rebind premise: tests/registration_known_gaps.

from std.testing import assert_equal, TestSuite

from muntin import (
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
    ToResponse,
    WithHeaders,
)
from registration_spike import Registrar


# Application types.


struct Note(FromBody, Movable):
    """A move-only body."""

    var text: String

    def __init__(out self, var text: String):
        self.text = text^

    @staticmethod
    def from_body(body: String) raises -> Self:
        if body == "bad":
            raise Error("bad body")
        return Self(body)


@fieldwise_init
struct Name(FromJson):
    var name: String

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        return Self(value["name"].string())


@fieldwise_init
struct Named(ToJson):
    var name: String

    def write_json(self, mut out: JsonWriter) raises:
        out.begin_object()
        out.name("name")
        out.string(self.name)
        out.end_object()


@fieldwise_init
struct Created(ToResponse):
    var id: Int

    def to_response(deinit self) -> Response:
        return Response(201, String(self.id))


@fieldwise_init
struct Unauthorized(ToErrorResponse):
    def to_error_response(deinit self) -> Response:
        return Response.text("Unauthorized", status=401)


struct Db(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


# Handlers: every shape production registers on get and post today.


def root() -> String:
    return "root"


def created() -> Created:
    return Created(1)


def by_id(id: Int) -> String:
    return "id " + String(id)


def by_id_owned(var id: Int) -> String:
    return "owned " + String(id)


def created_id(id: Int) -> Created:
    return Created(id)


def raw(req: Request) -> Response:
    return Response.text(req.method + " " + req.path + " " + req.body)


def note(body: Note) -> String:
    return "note " + body.text


def note_owned(var body: Note) -> String:
    return "owned " + body.text


def update(id: Int, body: Note) -> Created:
    return Created(id)


def json_name(body: Json[Name]) -> Json[Named]:
    return Json(Named(body.value.name))


def carried(input: WithHeaders[Note]) -> String:
    return input.body.text


def carried_id(id: Int, input: WithHeaders[Note]) -> String:
    return String(id) + " " + input.body.text


def version() -> StaticString:
    return "1.0"


def test_typed_static_string_value_registers() raises:
    """The third recorded change to the accepted set: a typed function
    value whose result is `StaticString` registers as text on the model.
    Production's text overloads take `def(...) -> String`, and a typed
    value does not convert, so `main` rejects it with the `TODO: function
    type conversions` error."""
    var reg = Registrar()
    var f: def() thin raises Never -> StaticString = version
    reg.on["GET", "/version"](f)
    assert_equal(reg.shapes[0], "GET () -> text")
    assert_equal(_show(reg.invoke(0, _args())), "200 1.0")


def guarded(id: Int) raises Unauthorized -> String:
    if id == 0:
        raise Unauthorized()
    return "ok"


def failing() raises -> String:
    raise Error("internal detail")


def count(db: State[Db]) -> String:
    return String(db[].n)


def count_id(db: State[Db], id: Int) -> String:
    return String(db[].n + id)


def stateful_raw(db: State[Db], req: Request) -> Response:
    return Response.text(String(db[].n) + " " + req.path)


def stateful_note(db: State[Db], body: Note) -> String:
    return String(db[].n) + " " + body.text


def stateful_update(db: State[Db], id: Int, var body: Note) -> String:
    return String(db[].n + id) + " " + body.text


# New slot types: no overload is added for them.


def by_name(name: String) -> String:
    return "name " + name


def by_id_and_name(id: Int, name: String) -> String:
    return String(id) + " " + name


def me(headers: Headers) -> String:
    return headers.get("x-user").or_else("anonymous")


def item_for(id: Int, headers: Headers) -> String:
    return String(id) + " " + headers.get("x-user").or_else("-")


def user_item(headers: Headers, id: Int) -> String:
    return headers.get("x-user").or_else("-") + " " + String(id)


def admin(db: State[Db], headers: Headers) -> String:
    return String(db[].n) + " " + headers.get("x-user").or_else("-")


def _args(*values: String) -> List[String]:
    var out = List[String]()
    for v in values:
        out.append(String(v))
    return out^


def _show(r: Response) -> String:
    return String(r.status) + " " + r.body


def test_current_shapes_select_one_overload_per_arity() raises:
    var db = State(Db(5))
    var reg = Registrar()
    reg.on["GET", "/"](root)
    reg.on["GET", "/c"](created)
    reg.on["GET", "/users/{id}"](by_id)
    reg.on["GET", "/items?{id}"](created_id)
    reg.on["GET", "/raw"](raw)
    reg.on["POST", "/notes"](note)
    reg.on["POST", "/notes/{id}"](update)
    reg.on["POST", "/json"](json_name)
    reg.on["POST", "/carried"](carried)
    reg.on["POST", "/raw"](raw)
    reg.on["GET", "/version"](version)
    reg.on["GET", "/guarded/{id}"](guarded)
    reg.on["GET", "/count"](count, db)
    reg.on["GET", "/count/{id}"](count_id, db)
    reg.on["GET", "/sraw"](stateful_raw, db)
    reg.on["POST", "/snote"](stateful_note, db)
    reg.on["POST", "/supdate/{id}"](stateful_update, db)
    var expected: List[String] = [
        "GET () -> text",
        "GET () -> converted",
        "GET (Int) -> text",
        "GET (Int) -> converted",
        "GET (Request) -> converted",
        "POST (body) -> text",
        "POST (Int, body) -> converted",
        "POST (body) -> converted",
        "POST (body) -> text",
        "POST (Request) -> converted",
        "GET () -> text",
        "GET (Int) -> text",
        "GET (State) -> text",
        "GET (State, Int) -> text",
        "GET (State, Request) -> converted",
        "POST (State, body) -> text",
        "POST (State, Int, body) -> text",
    ]
    assert_equal(len(reg.shapes), len(expected))
    for i in range(len(expected)):
        assert_equal(reg.shapes[i], expected[i])


def test_dispatch_matches_production() raises:
    var db = State(Db(5))
    var reg = Registrar()
    reg.on["GET", "/"](root)  # 0
    reg.on["GET", "/users/{id}"](by_id)  # 1
    reg.on["GET", "/items?{id}"](created_id)  # 2
    reg.on["GET", "/raw"](raw)  # 3
    reg.on["POST", "/notes"](note)  # 4
    reg.on["POST", "/notes/{id}"](update)  # 5
    reg.on["GET", "/version"](version)  # 6
    reg.on["GET", "/count/{id}"](count_id, db)  # 7
    reg.on["GET", "/sraw"](stateful_raw, db)  # 8
    reg.on["GET", "/count"](count, db)  # 9
    reg.on["POST", "/carried"](carried)  # 10
    reg.on["POST", "/sraw"](stateful_raw, db)  # 11
    reg.on["POST", "/supdate/{id}"](stateful_update, db)  # 12
    assert_equal(_show(reg.invoke(0, _args())), "200 root")
    assert_equal(_show(reg.invoke(1, _args("42"))), "200 id 42")
    assert_equal(_show(reg.invoke(2, _args("7"))), "201 7")
    assert_equal(
        _show(reg.invoke(3, _args("GET", "/raw", "b"))), "200 GET /raw b"
    )
    assert_equal(_show(reg.invoke(4, _args("hi"))), "200 note hi")
    assert_equal(_show(reg.invoke(5, _args("3", "hi"))), "201 3")
    assert_equal(_show(reg.invoke(6, _args())), "200 1.0")
    assert_equal(_show(reg.invoke(7, _args("2"))), "200 7")
    assert_equal(_show(reg.invoke(8, _args("GET", "/sraw", ""))), "200 5 /sraw")
    assert_equal(_show(reg.invoke(9, _args())), "200 5")
    assert_equal(_show(reg.invoke(10, _args("hi", "X-A", "1"))), "200 hi")
    assert_equal(
        _show(reg.invoke(11, _args("POST", "/sraw", "b"))), "200 5 /sraw"
    )
    assert_equal(_show(reg.invoke(12, _args("2", "hi"))), "200 7 hi")


def test_request_failures_answer_before_the_handler() raises:
    var reg = Registrar()
    reg.on["GET", "/users/{id}"](by_id)
    reg.on["POST", "/notes/{id}"](update)
    reg.on["POST", "/notes"](note)
    reg.on["POST", "/carried/{id}"](carried_id)
    assert_equal(_show(reg.invoke(0, _args("x"))), "400 Bad Request")
    assert_equal(_show(reg.invoke(1, _args("x", "bad"))), "400 Bad Request")
    assert_equal(_show(reg.invoke(2, _args("bad"))), "400 Bad Request")
    # The route value is converted before the body: with both invalid, the
    # bad route value (400) answers before the carrier's field rebuild
    # (500 for a field name `Headers.add` rejects).
    assert_equal(
        _show(reg.invoke(3, _args("x", "hi", "bad name", "v"))),
        "400 Bad Request",
    )
    assert_equal(
        _show(reg.invoke(3, _args("1", "hi", "bad name", "v"))),
        "500 Internal Server Error",
    )
    assert_equal(_show(reg.invoke(3, _args("1", "hi", "X-A", "v"))), "200 1 hi")


def test_error_model_is_production_s() raises:
    var reg = Registrar()
    reg.on["GET", "/guarded/{id}"](guarded)
    reg.on["GET", "/failing"](failing)
    assert_equal(_show(reg.invoke(0, _args("0"))), "401 Unauthorized")
    assert_equal(_show(reg.invoke(0, _args("1"))), "200 ok")
    assert_equal(_show(reg.invoke(1, _args())), "500 Internal Server Error")


def test_owned_and_borrowed_parameters_both_register() raises:
    """Every slot is `var A`, so an owned route value registers too (M2-009
    rejects `var id: Int` on production; the decision records the
    widening)."""
    var reg = Registrar()
    reg.on["GET", "/a/{id}"](by_id)
    reg.on["GET", "/b/{id}"](by_id_owned)
    reg.on["POST", "/c"](note)
    reg.on["POST", "/d"](note_owned)
    assert_equal(_show(reg.invoke(1, _args("4"))), "200 owned 4")
    assert_equal(_show(reg.invoke(3, _args("x"))), "200 owned x")


def test_new_slot_types_add_no_overload() raises:
    var db = State(Db(5))
    var reg = Registrar()
    reg.on["GET", "/users/{name}"](by_name)  # 0
    reg.on["GET", "/users/{id}/{name}"](by_id_and_name)  # 1
    reg.on["GET", "/me"](me)  # 2
    reg.on["GET", "/items/{id}"](item_for)  # 3
    reg.on["GET", "/user-items/{id}"](user_item)  # 4
    reg.on["GET", "/admin"](admin, db)  # 5
    assert_equal(reg.shapes[0], "GET (String) -> text")
    assert_equal(reg.shapes[1], "GET (Int, String) -> text")
    assert_equal(reg.shapes[2], "GET (Headers) -> text")
    assert_equal(reg.shapes[3], "GET (Int, Headers) -> text")
    assert_equal(reg.shapes[4], "GET (Headers, Int) -> text")
    assert_equal(reg.shapes[5], "GET (State, Headers) -> text")
    assert_equal(_show(reg.invoke(0, _args("ada"))), "200 name ada")
    assert_equal(_show(reg.invoke(1, _args("1", "ada"))), "200 1 ada")
    assert_equal(_show(reg.invoke(2, _args("X-User", "ada"))), "200 ada")
    assert_equal(_show(reg.invoke(2, _args())), "200 anonymous")
    assert_equal(_show(reg.invoke(3, _args("7", "X-User", "ada"))), "200 7 ada")
    # Headers declared first still reads its pairs after the value.
    assert_equal(_show(reg.invoke(4, _args("7", "X-User", "ada"))), "200 ada 7")
    assert_equal(_show(reg.invoke(5, _args("x-user", "bob"))), "200 5 bob")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
