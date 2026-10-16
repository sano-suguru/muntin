# One scan for a route's query values (pull request #123): `_query_spans`,
# which `App.handle` uses for every route with a query placeholder, must
# read a query exactly as `_query_value`, the one-key reader it replaced,
# reads it. Differential: for routes of 1, 2, 8 and 9 keys (the last
# compared, the first looked up in `_query_index`) and 12, every query of a
# fixed set (keys out of order, missing, duplicated, bare, empty, values
# holding `=`, empty pairs, unrelated keys and values with multibyte UTF-8,
# many unrelated pairs) gives each key the value `_query_value` gives it,
# sliced at `_query_spans`' byte offsets, and raises exactly when one of the
# keys is duplicated. Through `App.handle`: tests/test_route_values.mojo and
# tests/test_route_records.mojo.

from std.collections import Dict
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from muntin.app import (
    _LINEAR_QUERY_KEYS,
    _query_index,
    _query_spans,
    _query_value,
)


def _keys(n: Int) -> List[String]:
    var keys = List[String]()
    for k in range(n):
        keys.append("k" + String(k))
    return keys^


def _join(pairs: List[String]) -> String:
    return "&".join(pairs)


def _queries(keys: List[String]) -> List[String]:
    """Queries over `keys` exercising every way a pair can read."""
    var n = len(keys)
    var queries = List[String]()
    var forward = List[String]()
    var backward = List[String]()
    for k in range(n):
        forward.append(keys[k] + "=v" + String(k))
        backward.append(keys[n - 1 - k] + "=w" + String(n - 1 - k))
    queries.append(_join(forward))
    queries.append(_join(backward))
    queries.append("")
    queries.append("u=日本語&" + _join(backward) + "&ü=ö")
    queries.append("日本=語&&" + "&&".join(forward) + "&")
    queries.append("&" + _join(forward) + "&&")
    queries.append("=x&" + _join(forward))
    # The first key missing, the last one duplicated.
    var missing = forward.copy()
    _ = missing.pop(0)
    queries.append(_join(missing))
    queries.append(_join(forward) + "&" + keys[n - 1] + "=again")
    # A bare key and an empty value.
    var bare = forward.copy()
    bare[0] = keys[0]
    if n > 1:
        bare[1] = keys[1] + "="
    queries.append(_join(bare))
    # Values holding `=`, multibyte values, keys that a key prefixes.
    var odd = List[String]()
    for k in range(n):
        odd.append(keys[k] + "x=no")
        odd.append(keys[k] + "=a=b" + String(k) + "é")
        odd.append(keys[k][byte=:1] + "=no")
    queries.append(_join(odd))
    # Many unrelated pairs around the keys.
    var many = List[String]()
    for i in range(200):
        many.append("z" + String(i) + "=ü" + String(i))
        if i % 23 == 0 and i // 23 < n:
            many.append(keys[i // 23] + "=日" + String(i))
    queries.append(_join(many))
    return queries^


def _check(query: String, keys: List[String]) raises:
    var expected = List[Optional[String]]()
    var duplicated = False
    for k in range(len(keys)):
        try:
            expected.append(_query_value(query, keys[k]))
        except:
            duplicated = True
            expected.append(None)
    var spans: List[Int]
    try:
        spans = _query_spans(query, keys, _query_index(keys))
    except:
        assert_true(duplicated, "raised without a duplicate: " + query)
        return
    assert_false(duplicated, "a duplicate did not raise: " + query)
    for k in range(len(keys)):
        var start = spans[2 * k]
        var end = spans[2 * k + 1]
        if not expected[k]:
            assert_equal(start, -1, keys[k] + " in " + query)
            assert_equal(end, -1, keys[k] + " in " + query)
        else:
            assert_true(start >= 0 and start <= end, keys[k] + " in " + query)
            assert_equal(
                String(query[byte=start:end]),
                expected[k].value(),
                keys[k] + " in " + query,
            )


def test_spans_read_every_query_as_the_one_key_reader() raises:
    for n in [1, 2, _LINEAR_QUERY_KEYS, _LINEAR_QUERY_KEYS + 1, 12]:
        var keys = _keys(n)
        for query in _queries(keys):
            _check(query, keys)


def test_only_routes_above_the_limit_keep_an_index() raises:
    assert_equal(len(_query_index(_keys(_LINEAR_QUERY_KEYS))), 0)
    var index = _query_index(_keys(_LINEAR_QUERY_KEYS + 1))
    assert_equal(len(index), _LINEAR_QUERY_KEYS + 1)
    assert_equal(index["k0"], 0)
    assert_equal(index["k8"], 8)


def test_multibyte_text_before_a_value_shifts_its_bytes() raises:
    var keys: List[String] = ["a", "b"]
    var query = String("unrelated=日本語&a=42&b=hello")
    var spans = _query_spans(query, keys, _query_index(keys))
    assert_equal(String(query[byte = spans[0] : spans[1]]), "42")
    assert_equal(String(query[byte = spans[2] : spans[3]]), "hello")
    assert_equal(spans[0], 22)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
