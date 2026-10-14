# Named route values (M3-050), an opt-in check: a `Param[name, T]` route
# value has the kind, decoding and 400s of its `T`, its name is compared with
# the placeholder at its position at registration, and of two values both or
# neither are `Param`s. Through `App.handle` and `TestClient`: docs/DX.md's
# example as written, two `Param`s on every method (stateless and stateful,
# with a body, `Headers`, query values and bodyless), a lone named value,
# `Param` itself, and the known gap that a variable's own name is not
# compared. Bare values are unchanged (tests/test_route_values.mojo).
# Decision: docs/history/architecture-decisions.md, "Named route values
# decision (M3-050)". Must-not-compile counterparts:
# tests/named_values_api_fail.

from std.testing import assert_equal, TestSuite

from muntin import App, FromBody, Headers, Param, State
from muntin.testing import TestClient


struct Prefix(Movable):
    var text: String

    def __init__(out self, text: String):
        self.text = text


struct Note(FromBody, Movable):
    var text: String

    def __init__(out self, var text: String):
        self.text = text^

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


# docs/DX.md, "Named route values", as written there.


def post_of(uid: Int, pid: Int) -> String:
    return String("post ", pid, " of user ", uid)


def checked_post_of(uid: Param["uid", Int], pid: Param["pid", Int]) -> String:
    return String("post ", pid.value, " of user ", uid.value)


def _dx_app() -> App:
    """docs/DX.md's registrations, as written there, on its own `App`."""
    var app = App()
    app.get["/users/{uid}/posts/{pid}"](post_of)
    app.get["/checked/{uid}/posts/{pid}"](checked_post_of)
    return app^


def with_body(
    uid: Param["uid", Int], pid: Param["pid", Int], body: Note
) -> String:
    return String(uid.value, ",", pid.value, "=", body.text)


def query_pair(q: Param["q", String], limit: Param["limit", Int]) -> String:
    return String(limit.value, " results for ", q.value)


def bodyless(a: Param["a", String], b: Param["b", String]) -> String:
    return String(a.value, ",", b.value)


def with_headers(
    uid: Param["uid", Int], pid: Param["pid", Int], headers: Headers
) -> String:
    return String(uid.value, ",", pid.value, " ", len(headers))


def stateful(
    p: State[Prefix], uid: Param["uid", Int], tag: Param["tag", String]
) -> String:
    return String(p[].text, uid.value, ",", tag.value)


def named_one(id: Param["id", Int]) -> String:
    return String("named ", id.value)


def named_optional(limit: Param["limit", Optional[Int]]) -> String:
    return String("limit ", limit.value.or_else(20))


def misled(pid: Param["uid", Int], uid: Param["pid", Int]) -> String:
    # Each variable is named after the other placeholder; only the `Param`
    # names are compared, so this registers on /users/{uid}/posts/{pid}.
    return String("post ", pid.value, " of user ", uid.value)


def _expect(app: App, target: String, status: Int, body: String) raises:
    var r = TestClient(app).get(target)
    assert_equal(r.status, status, target)
    assert_equal(r.text(), body, target)


def test_dx_example() raises:
    var app = _dx_app()
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


def test_variable_names_are_not_compared() raises:
    # Known constraint: Mojo 1.1.0 cannot reflect a parameter's name, so a
    # variable named after another placeholder registers and receives the
    # value its `Param` name binds: `pid` holds the user's id here. If this
    # stops registering or binding this way, the record's "Revisit when" has
    # fired.
    var app = App()
    app.get["/users/{uid}/posts/{pid}"](misled)
    _expect(app, "/users/1/posts/2", 200, "post 1 of user 2")


def _tests() -> TestSuite:
    """This module's tests, registered by hand: discovering them
    (`TestSuite.discover_tests[__functions_in_module()]`) crashes Mojo 1.1.0
    because a handler here declares a `Param` (M3-050;
    tests/named_values_api_fail/discover_tests_crash.mojo).
    `scripts/check_test_lists.sh` checks that every `test_` function is
    listed."""
    var suite = TestSuite()
    suite.test[test_dx_example]()
    suite.test[test_two_params_on_every_method]()
    suite.test[test_one_value_may_be_named]()
    suite.test[test_param_holds_and_copies_its_value]()
    suite.test[test_variable_names_are_not_compared]()
    return suite^


def main() raises:
    _tests().run()
