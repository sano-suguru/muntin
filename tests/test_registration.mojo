# Registration on generic-arity slots (M3-015): the accepted-set edges the
# restructure ships. Edge 1: an owned `Int` route value registers on `get` and
# `post`. Edge 2: a typed `-> StaticString` function value registers, also
# through a helper parameter; `StaticString` and string-literal results are
# text. Edge 3 (the narrowed one, tests/registration_api_fail): a typed value
# with a borrowed `Int` no longer registers, and the `var` spelling does. Edge
# 4, added by M3-015's amendment of M3-014: helpers generic over the result
# (`where R == String`, `where R == StaticString`) or over a request parameter
# (`def(var A)`, `def(State[S], var A)`, `def(var A, var B)`, a raw `Request`
# slot) forward to `get` and `post`. Decision:
# docs/history/architecture-decisions.md, "Registration structure decision
# (M3-014)" and "Registration structure amendment: generic forwarding (M3-015)".

from std.testing import assert_equal, TestSuite

from muntin import App, FromBody, Request, Response, State, ToResponse
from muntin.testing import TestClient


struct Note(FromBody):
    var text: String

    def __init__(out self, var text: String):
        self.text = text^

    @staticmethod
    def from_body(body: String) raises -> Self:
        if body == "bad":
            raise Error("bad body")
        return Self(body)


@fieldwise_init
struct Db(Movable):
    var name: String


def get_user(var id: Int) -> String:
    id += 1
    return String("user ", id)


def update_note(var id: Int, body: Note) -> String:
    id *= 10
    return String("note ", id, ": ", body.text)


def stateful_update(db: State[Db], var id: Int, var body: Note) -> String:
    return String(db[].name, " ", id, ": ", body.text)


def static_text() -> StaticString:
    return "static"


def literal_text() -> type_of("literal"):
    return "literal"


def string_text() -> String:
    return "static"


def by_id(var id: Int) -> String:
    return String("typed ", id)


def register_static[
    E: Deinitable
](mut app: App, h: def() thin raises E -> StaticString):
    """A generic helper forwarding a typed `-> StaticString` value."""
    app.get["/helper"](h)


@fieldwise_init
struct Count(ToResponse):
    var n: Int

    def to_response(deinit self) -> Response:
        return Response.text(String("count ", self.n))


def count() -> Count:
    return Count(3)


def raw_path(req: Request) -> Response:
    return Response.text(String("raw ", req.method, " ", req.path))


def stateful_by_id(db: State[Db], id: Int) -> String:
    return String(db[].name, " ", id)


# Generic forwarding (edge 4, the M3-015 amendment of M3-014): helpers
# generic over the result or a request parameter, forwarding to `get` and
# `post`. Each registers on the generic-arity overloads; on the per-shape
# overloads each was `no matching method`, except the conformance branch,
# which `main`'s `ToResponse` overloads already took (a control).


def register_text[
    R: Movable & Deinitable
](mut app: App, h: def() thin raises Never -> R) where R == String:
    """Generic result, `where R == String`."""
    app.get["/generic"](h)


def register_static_r[
    R: Movable & Deinitable
](mut app: App, h: def() thin raises Never -> R) where R == StaticString:
    """Generic result, `where R == StaticString`."""
    app.get["/generic-static"](h)


def register_converted[
    R: Movable & Deinitable
](mut app: App, h: def() thin raises Never -> R) where conforms_to(
    R, ToResponse
):
    """Generic result, `where conforms_to(R, ToResponse)` (registered on
    `main` too)."""
    app.get["/generic-converted"](h)


def register_slot_get[
    A: Movable & Deinitable
](mut app: App, h: def(var A) thin raises Never -> String):
    """Generic slot on `get` (an `Int` route value here)."""
    app.get["/slot/{id}"](h)


def register_slot_state_get[
    S: Movable & Deinitable, A: Movable & Deinitable
](
    mut app: App,
    h: def(State[S], var A) thin raises Never -> String,
    st: State[S],
):
    """Generic slot after a `State` on `get`."""
    app.get["/state-slot/{id}"](h, st)


def register_slots_post[
    A: Movable & Deinitable, B: Movable & Deinitable
](mut app: App, h: def(var A, var B) thin raises Never -> String):
    """Two generic slots on `post` (an `Int` route value, then a body)."""
    app.post["/slots/{id}"](h)


def register_slots_state_post[
    S: Movable & Deinitable, A: Movable & Deinitable, B: Movable & Deinitable
](
    mut app: App,
    h: def(State[S], var A, var B) thin raises Never -> String,
    st: State[S],
):
    """Two generic slots after a `State` on `post`."""
    app.post["/state-slots/{id}"](h, st)


def register_raw_state_slot[
    S: Movable & Deinitable, A: Movable & Deinitable
](
    mut app: App,
    h: def(State[S], var A) thin raises Never -> Response,
    st: State[S],
):
    """A generic slot filled by `Request` after a `State`, on both methods."""
    app.get["/state-raw-slot"](h, st)
    app.post["/state-raw-slot"](h, st)


def register_body_text[
    R: Movable & Deinitable
](mut app: App, h: def(var Note) thin raises Never -> R) where R == String:
    """Generic result on `post`."""
    app.post["/body-generic"](h)


def register_slot_and_result[
    A: Movable & Deinitable, R: Movable & Deinitable
](mut app: App, h: def(var A) thin raises Never -> R) where R == String:
    """Generic slot and generic result together."""
    app.get["/slot-generic/{id}"](h)


def register_full_clause[
    R: Movable & Deinitable
](mut app: App, h: def() thin raises Never -> R) where (
    R == String or R == StaticString or conforms_to(R, ToResponse)
):
    """The registration's own clause, copied verbatim."""
    app.get["/full-clause"](h)


def register_full_clause_reordered[
    R: Movable & Deinitable
](mut app: App, h: def() thin raises Never -> R) where (
    R == StaticString or R == String or conforms_to(R, ToResponse)
):
    """The registration's clause with its branches reordered."""
    app.get["/full-clause-reordered"](h)


def note_text(var body: Note) -> String:
    return String("note ", body.text)


def stateful_raw(db: State[Db], req: Request) -> Response:
    return Response.text(String(db[].name, " ", req.method))


def register_raw_slot[
    A: Movable & Deinitable
](mut app: App, h: def(var A) thin raises Never -> Response):
    """A generic slot filled by `Request`: a raw handler on both methods."""
    app.get["/raw-slot"](h)
    app.post["/raw-slot"](h)


def test_owned_route_value_registers_on_get() raises:
    var app = App()
    app.get["/users/{id}"](get_user)
    app.get["/items?{id}"](get_user)
    var client = TestClient(app^)
    var r = client.get("/users/41")
    assert_equal(r.status, 200)
    assert_equal(r.text(), "user 42")
    assert_equal(client.get("/items?id=1").text(), "user 2")
    assert_equal(client.get("/users/x").status, 400)


def test_owned_route_value_registers_on_post() raises:
    var app = App()
    app.post["/notes/{id}"](update_note)
    app.post["/stateful/{id}"](stateful_update, State(Db("db")))
    var client = TestClient(app^)
    var r = client.post("/notes/7", "hi")
    assert_equal(r.status, 200)
    assert_equal(r.text(), "note 70: hi")
    assert_equal(client.post("/stateful/3", "x").text(), "db 3: x")
    # The route value is still converted before the body.
    assert_equal(client.post("/notes/x", "bad").status, 400)
    assert_equal(client.post("/notes/7", "bad").status, 400)


def test_static_string_and_literal_results_are_text() raises:
    var app = App()
    app.get["/static"](static_text)
    app.get["/literal"](literal_text)
    app.get["/string"](string_text)
    var client = TestClient(app^)
    var s = client.get("/static")
    var t = client.get("/string")
    assert_equal(s.status, 200)
    assert_equal(s.text(), "static")
    assert_equal(len(s.headers), len(t.headers))
    var l = client.get("/literal")
    assert_equal(l.status, 200)
    assert_equal(l.text(), "literal")


def test_typed_var_int_value_registers() raises:
    var app = App()
    var f: def(var Int) thin raises Never -> String = by_id
    app.get["/typed/{id}"](f)
    var client = TestClient(app^)
    assert_equal(client.get("/typed/5").text(), "typed 5")
    assert_equal(client.get("/typed/x").status, 400)


def test_typed_static_string_value_registers() raises:
    var app = App()
    var f: def() thin raises Never -> StaticString = static_text
    app.get["/typed"](f)
    var client = TestClient(app^)
    var r = client.get("/typed")
    assert_equal(r.status, 200)
    assert_equal(r.text(), "static")


def test_generic_helper_forwards_a_typed_static_string_value() raises:
    var app = App()
    register_static(app, static_text)
    var client = TestClient(app^)
    var r = client.get("/helper")
    assert_equal(r.status, 200)
    assert_equal(r.text(), "static")


def test_generic_result_helper_forwards_a_text_value() raises:
    var app = App()
    register_text(app, string_text)
    var client = TestClient(app^)
    var r = client.get("/generic")
    assert_equal(r.status, 200)
    assert_equal(r.text(), "static")


def test_generic_result_helpers_forward_each_where_branch() raises:
    var app = App()
    register_static_r(app, static_text)
    register_converted(app, count)
    var client = TestClient(app^)
    var s = client.get("/generic-static")
    assert_equal(s.status, 200)
    assert_equal(s.text(), "static")
    var c = client.get("/generic-converted")
    assert_equal(c.status, 200)
    assert_equal(c.text(), "count 3")


def test_generic_slot_helpers_forward() raises:
    var app = App()
    register_slot_get(app, by_id)
    register_slot_state_get(app, stateful_by_id, State(Db("db")))
    register_slots_post(app, update_note)
    register_raw_slot(app, raw_path)
    var client = TestClient(app^)
    assert_equal(client.get("/slot/5").text(), "typed 5")
    assert_equal(client.get("/slot/x").status, 400)
    assert_equal(client.get("/state-slot/4").text(), "db 4")
    assert_equal(client.post("/slots/2", "hi").text(), "note 20: hi")
    assert_equal(client.post("/slots/x", "bad").status, 400)
    assert_equal(client.get("/raw-slot").text(), "raw GET /raw-slot")
    assert_equal(client.post("/raw-slot", "b").text(), "raw POST /raw-slot")


def test_more_generic_forwarding_forms() raises:
    var app = App()
    var db = State(Db("db"))
    register_slots_state_post(app, stateful_update, db)
    register_raw_state_slot(app, stateful_raw, db)
    register_body_text(app, note_text)
    register_slot_and_result(app, by_id)
    register_full_clause(app, static_text)
    register_full_clause_reordered(app, static_text)
    var client = TestClient(app^)
    assert_equal(client.post("/state-slots/3", "x").text(), "db 3: x")
    assert_equal(client.get("/state-raw-slot").text(), "db GET")
    assert_equal(client.post("/state-raw-slot", "b").text(), "db POST")
    assert_equal(client.post("/body-generic", "b").text(), "note b")
    assert_equal(client.get("/slot-generic/6").text(), "typed 6")
    assert_equal(client.get("/full-clause").text(), "static")
    var r = client.get("/full-clause-reordered")
    assert_equal(r.status, 200)
    assert_equal(r.text(), "static")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
