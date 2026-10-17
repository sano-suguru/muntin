# Named route values (M3-050), an opt-in check: a `Param[name, T]` route value
# has the kind, decoding and 400s of its `T`, its name is compared with the
# placeholder at its position at registration, and of two values both or neither
# are `Param`s. Through `App.handle` and `TestClient`: the
# docs/reference/route-values.md example as written, two `Param`s on every
# method (stateless and stateful, with a body, `Headers`, query values and
# bodyless), a lone named value, `Param` itself, and the known gap that a
# variable's own name is not compared. Bare values are unchanged
# (tests/test_route_values.mojo). The handlers are in
# tests/named_value_handlers.mojo, so this module can discover its tests.
# Decision: docs/history/architecture-decisions.md, "Named route values decision
# (M3-050)". Must-not-compile counterparts: tests/named_values_api_fail.

from std.testing import assert_equal, TestSuite

from muntin import App, Headers, Param, State
from named_value_handlers import (
    Prefix,
    bodyless,
    make_app,
    misled,
    same_names,
    named_one,
    named_optional,
    query_pair,
    stateful,
    with_body,
    with_headers,
)
from muntin.testing import TestClient


def _expect(app: App, target: String, status: Int, body: String) raises:
    var r = TestClient(app).get(target)
    assert_equal(r.status, status, target)
    assert_equal(r.text(), body, target)


def test_dx_example() raises:
    var app = make_app()
    _expect(app, "/users/1/posts/2", 200, "post 2 of user 1")
    _expect(app, "/checked/1/posts/2", 200, "post 2 of user 1")
    _expect(app, "/checked/1/posts/x", 400, "Bad Request")


def test_two_params_on_every_method() raises:
    var app = App()
    app.post["/users/{uid}/posts/{pid}"](with_body)
    app.put["/search?{q}&{limit}"](query_pair)
    app.patch["/x/{a}/{b}"](bodyless)
    app.delete["/users/{uid}/posts/{pid}"](with_headers)
    app.get["/st/{uid}?{tag}"](stateful, State(Prefix("p:")))
    var client = TestClient(app)
    var r = client.post("/users/1/posts/2", "hi")
    assert_equal(r.text(), "1,2=hi")
    r = client.post("/users/1/posts/x", "hi")
    assert_equal(r.status, 400)
    r = client.put("/search?limit=5&q=mojo", "")
    assert_equal(r.text(), "5 results for mojo")
    r = client.patch("/x/a%20b/c", "ignored")
    assert_equal(r.text(), "a b,c")
    var h = Headers()
    h.add("X-A", "1")
    r = client.delete("/users/3/posts/4", headers=h^)
    assert_equal(r.text(), "3,4 1")
    _expect(app, "/st/7?tag=new", 200, "p:7,new")
    _expect(app, "/st/7", 400, "Bad Request")


def test_one_value_may_be_named() raises:
    # A `Param` converts as its bare type would; a lone value may be either.
    var app = App()
    app.get["/n/{id}"](named_one)
    app.get["/o?{limit}"](named_optional)
    _expect(app, "/n/042", 200, "named 42")
    _expect(app, "/n/x", 400, "Bad Request")
    _expect(app, "/o", 200, "limit 20")
    _expect(app, "/o?limit=5", 200, "limit 5")
    _expect(app, "/o?limit=x", 400, "Bad Request")


def test_param_holds_and_copies_its_value() raises:
    var id = Param["id", Int](7)
    var copy = id.copy()
    copy.value += 1
    assert_equal(id.value, 7)
    assert_equal(copy.value, 8)
    var text = Param["q", String]("mojo")
    assert_equal(text.value, "mojo")


def test_repeated_names_bind_by_position() raises:
    # Two placeholders with one name pass the name check whichever value is
    # which; binding stays by position.
    var app = App()
    app.get["/x/{a}/{a}"](same_names)
    _expect(app, "/x/1/2", 200, "1,2")


def test_variable_names_are_not_compared() raises:
    # Known constraint: Mojo 1.1.0 cannot reflect a parameter's name, so a
    # variable named after another placeholder registers and receives the
    # value its `Param` name binds: `pid` holds the user's id here. If this
    # stops registering or binding this way, the record's "Revisit when" has
    # fired.
    var app = App()
    app.get["/users/{uid}/posts/{pid}"](misled)
    _expect(app, "/users/1/posts/2", 200, "post 1 of user 2")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
