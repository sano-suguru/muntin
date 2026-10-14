# Route-literal grammar: the registration rules' parsers (`_path_params`,
# `_query_params`, `_distinct_query_keys`), the route `_Route.__init__`
# builds from the literal, and `_match` agree on a table of literals; all
# three read the literal through the primitives in
# src/muntin/_registration_rules.mojo. The rules' message for malformed
# literals: the must-not-build fixtures that expect `malformed route
# literal`.

from std.testing import assert_equal, assert_false, assert_true, TestSuite

from muntin import App, Request, Response
from muntin._handler_storage import _Erased
from muntin._registration_rules import (
    _distinct_query_keys,
    _is_param,
    _param_name,
    _path_params,
    _query_items,
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
    bytes: List[UInt8],
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


def _malformed_path[literal: StaticString]() raises:
    comptime paths = _path_params(literal)
    assert_true(paths < 0, String(literal))


def _malformed_query[literal: StaticString]() raises:
    comptime paths = _path_params(literal)
    comptime queries = _query_params(literal)
    assert_true(paths >= 0 and queries < 0, String(literal))


def test_malformed_literals() raises:
    # Path part (docs/DX.md, "malformed route literal").
    _malformed_path["hello"]()
    _malformed_path[""]()
    _malformed_path["?{q}"]()
    _malformed_path["/{}"]()
    _malformed_path["/{a}b"]()
    _malformed_path["/a{b}"]()
    _malformed_path["/{a"]()
    _malformed_path["/a}"]()
    _malformed_path["/{{a}}"]()
    _malformed_path["/{a}}"]()
    # Query part.
    _malformed_query["/a?"]()
    _malformed_query["/a?limit"]()
    _malformed_query["/a?{}"]()
    _malformed_query["/a?{lim it}"]()
    _malformed_query["/a?{límit}"]()
    _malformed_query["/a?{a=b}"]()
    _malformed_query["/a?{a?b}"]()
    _malformed_query["/a?{a#b}"]()
    _malformed_query["/a?{{a}}"]()
    _malformed_query["/a?{a}b"]()
    _malformed_query["/a?{a}&"]()
    _malformed_query["/a?&{a}"]()
    _malformed_query["/a?{a}&&{b}"]()
    _malformed_query["/a?{q}?"]()
    _malformed_query["/a?{q}?{r}"]()


def test_query_items_tell_no_query_from_an_empty_one() raises:
    # `/a` has no query part; `/a?` has an empty one, which the query
    # checks must see as one (empty, so malformed) item.
    assert_equal(len(_query_items("/a")), 0)
    assert_equal(len(_query_items("/a?")), 1)
    assert_equal(_query_items("/a?")[0].byte_length(), 0)
    assert_equal(len(_query_items("/a?{q}&{r}")), 2)


def _brace_round_trip(item: StaticString) raises:
    assert_true(_is_param(item), String(item))
    assert_equal(String("{", _param_name(item), "}"), String(item))


def test_param_name_strips_what_is_param_recognizes() raises:
    # `_is_param` and `_param_name` both know the brace shape; the name is
    # what lies between the braces `_is_param` checked, nothing more.
    _brace_round_trip("{a}")
    _brace_round_trip("{id}")
    _brace_round_trip("{!~}")
    _brace_round_trip("{a}b}")
    assert_false(_is_param("{}"))
    assert_false(_is_param("{a"))
    assert_false(_is_param("a}"))
    assert_false(_is_param(""))


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
