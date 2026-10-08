# Route-literal grammar: the registration rules' parsers (`_path_params`,
# `_query_params`, `_distinct_query_keys`), the route `_Route.__init__`
# builds from the literal, and `_match` agree on every literal, through the
# primitives in src/muntin/_registration_rules.mojo. The rules' messages
# for malformed literals: tests/registration_fail and the other *_fail
# fixtures that expect `malformed route literal`.

from std.testing import assert_equal, assert_false, assert_true, TestSuite

from muntin import App, Request, Response
from muntin._handler_storage import _Erased
from muntin._registration_rules import (
    _distinct_query_keys,
    _path_params,
    _query_params,
)
from muntin.app import _Route, _match


def _unused(args: List[String]) raises -> Response:
    return Response.text("")


def _route_of(literal: StaticString) -> _Route:
    var handler: def(args: List[String]) thin raises -> Response = _unused
    return _Route("GET", literal, _Erased.__init__[call=_call](handler))


def _call(
    handler: def(args: List[String]) thin raises -> Response,
    args: List[String],
) raises -> Response:
    return handler(args)


def _agrees[
    literal: StaticString
](request_path: String, path_values: List[String], keys: List[String]) raises:
    """`literal`'s counts, evaluated at compile time as the rules evaluate
    them, match what the route built from it captures from `request_path`
    and the query keys it holds."""
    comptime paths = _path_params(literal)
    comptime queries = _query_params(literal)
    comptime assert paths >= 0 and queries >= 0
    var route = _route_of(literal)
    var args = List[String]()
    assert_true(_match(route.path, request_path, args))
    assert_equal(len(args), paths)
    assert_equal(args, path_values)
    assert_equal(len(route.query_keys), queries)
    assert_equal(route.query_keys, keys)


def test_well_formed_literals_agree() raises:
    _agrees["/"]("/", [], [])
    _agrees["/hello"]("/hello", [], [])
    _agrees["/users/{id}"]("/users/7", ["7"], [])
    _agrees["/{a}/{b}"]("/x/y", ["x", "y"], [])
    _agrees["/a/{id}/b"]("/a/%41/b", ["%41"], [])
    _agrees["/items?{limit}"]("/items", [], ["limit"])
    _agrees["/search?{q}&{limit}"]("/search", [], ["q", "limit"])
    _agrees["/users/{id}?{q}"]("/users/3", ["3"], ["q"])
    _agrees["/a?{!~}"]("/a", [], ["!~"])
    # A path segment with no braces is static, whatever else it holds.
    _agrees["/a=b/c%20d"]("/a=b/c%20d", [], [])


def test_static_and_empty_segments_do_not_match() raises:
    var route = _route_of("/users/{id}")
    var args = List[String]()
    assert_false(_match(route.path, "/users/", args))
    assert_false(_match(route.path, "/users", args))
    assert_false(_match(route.path, "/user/7", args))
    assert_false(_match(route.path, "/users/7/x", args))


def _malformed[literal: StaticString]() raises:
    comptime paths = _path_params(literal)
    comptime queries = _query_params(literal)
    assert_true(paths < 0 or queries < 0, String(literal))


def test_malformed_literals() raises:
    # Path part (docs/DX.md, "malformed route literal").
    _malformed["hello"]()
    _malformed[""]()
    _malformed["?{q}"]()
    _malformed["/{}"]()
    _malformed["/{a}b"]()
    _malformed["/a{b}"]()
    _malformed["/{a"]()
    _malformed["/a}"]()
    _malformed["/{{a}}"]()
    _malformed["/{a}}"]()
    # Query part.
    _malformed["/a?"]()
    _malformed["/a?limit"]()
    _malformed["/a?{}"]()
    _malformed["/a?{lim it}"]()
    _malformed["/a?{límit}"]()
    _malformed["/a?{a=b}"]()
    _malformed["/a?{a?b}"]()
    _malformed["/a?{a#b}"]()
    _malformed["/a?{{a}}"]()
    _malformed["/a?{a}b"]()
    _malformed["/a?{a}&"]()
    _malformed["/a?&{a}"]()
    _malformed["/a?{a}&&{b}"]()
    _malformed["/a?{q}?"]()
    _malformed["/a?{q}?{r}"]()


def test_query_keys_compare_whole() raises:
    comptime assert not _distinct_query_keys("/a?{q}&{q}")
    comptime assert _distinct_query_keys("/a?{q}&{qq}")
    comptime assert _distinct_query_keys("/a?{q}&{Q}")
    comptime assert _distinct_query_keys("/{q}?{q}")
    comptime assert _distinct_query_keys("/a")


def _value_and_optional(id: Int, q: Optional[Int]) -> String:
    return String(id, " ", q.or_else(-1))


def test_optional_key_is_indexed_after_the_path_values() raises:
    # `_route` marks query key `j - paths` optional for slot `j`, with
    # `paths` from `_path_params`; the key is the one `_Route` split out.
    var app = App()
    app.get["/u/{id}?{q}"](_value_and_optional)
    assert_equal(app._routes[0].query_keys, ["q"])
    assert_equal(app._routes[0].query_optional, [True])
    assert_equal(app.handle(Request("GET", "/u/4")).text(), "4 -1")
    assert_equal(app.handle(Request("GET", "/u/4?q=9")).text(), "4 9")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
