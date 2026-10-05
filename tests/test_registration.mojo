# Registration on generic-arity slots (M3-015): the accepted-set edges the
# restructure ships. An owned `Int` route value registers on `get` and `post`;
# `StaticString` and string-literal results register as text; an explicitly
# typed function value spelled with `var` slots registers, and so does a typed
# `-> StaticString` value, also through a generic helper parameter, and a
# helper generic over its result type whose own `where` clause proves the
# registration's. On the per-shape overloads before M3-015 the owned route
# value and the `var` spelling were `no matching method`, and the typed
# `StaticString` value and helper were `TODO: function type conversions
# between closures not supported yet`, and the generic-result helper `no
# matching method`. The narrowed edge (a typed value with a borrowed `Int`) is
# tests/registration_api_fail. Decision: docs/ARCHITECTURE.md, "Registration
# structure decision (M3-014)".

from std.testing import assert_equal, TestSuite

from muntin import App, FromBody, State
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


def register_text[
    R: Movable & Deinitable
](mut app: App, h: def() thin raises Never -> R) where R == String:
    """A helper generic over the result, whose own `where` clause proves the
    registration's."""
    app.get["/generic"](h)


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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
