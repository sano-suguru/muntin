"""Pins the compatibility condition M3-066 rests on and tests its prototype
rebuild (pull request #119; runs only in the `flare` environment, from
scripts/check_flare.sh).

`pieces_rebuild.mojo` reads request fields from the pieces Flare v0.12.0's
`HeaderMap.write_to` hands a `Writer`: name, `": "`, value and CRLF, four
`write_string` calls per field. Nothing in Flare documents that split, so
these tests pin it for the fields an adapter must read exactly, and a pin
change that alters it fails here before any request is misread. They also
check that the prototype rebuilds what the adapter's current
`to_muntin_headers` rebuilds and refuses what it refuses, and that pieces
of another shape are refused as the server's fault (`None`), not the
client's (a raise).
"""

from std.collections import Optional
from std.testing import (
    assert_equal,
    assert_false,
    assert_not_equal,
    assert_true,
    TestSuite,
)

from flare.http import HeaderMap, Request as FlareRequest
from muntin import Headers
from muntin_flare import to_muntin_headers
from pieces_rebuild import (
    FieldPieces,
    pieces_match,
    rebuild,
    rebuild_fields,
    write_to_splits_fields,
)


def _octets(values: List[Int]) -> String:
    var b = List[UInt8]()
    for v in values:
        b.append(UInt8(v))
    return String(unsafe_from_utf8=Span(b))


def _request(fields: List[Tuple[String, String]]) raises -> FlareRequest:
    """`append` checks only CR and LF, so shapes only HTTP/2 delivers (a
    control byte, bytes that are not UTF-8) are built in process."""
    var r = FlareRequest("GET", "/")
    for f in fields:
        r.headers.append(f[0], f[1])
    return r^


def _pieces(h: HeaderMap) -> List[String]:
    var p = FieldPieces()
    h.write_to(p)
    var out = List[String]()
    var start = 0
    for end in p.ends:
        out.append(String(from_utf8_lossy=Span(p.bytes)[start:end]))
        start = end
    return out^


def _listed(h: Headers) -> List[Tuple[String, String]]:
    var out = List[Tuple[String, String]]()
    for i in range(len(h)):
        out.append((h.name(i), h.value(i)))
    return out^


def _mismatch(
    got: List[Tuple[String, String]], want: List[Tuple[String, String]]
) -> String:
    """Empty when `got` and `want` hold the same fields, compared one by
    one by count, name and value; else the first difference."""
    if len(got) != len(want):
        return String("count ", len(got), " != ", len(want))
    for i in range(len(want)):
        if got[i][0] != want[i][0]:
            return String("name ", i, ": ", got[i][0], " != ", want[i][0])
        if got[i][1] != want[i][1]:
            return String("value ", i, ": ", got[i][1], " != ", want[i][1])
    return String()


def test_write_to_hands_four_pieces_per_field() raises:
    var long = String()
    for _ in range(100_000):
        long += "v"
    var r = _request(
        [
            (String("x-user:admin"), String("v: w")),
            (String("X-Empty"), String("")),
            (String("x-bad"), _octets([0xFF, 0x80])),
            (String("X-Long"), long),
            (String("X-Space"), String(" \t admin \t ")),
        ]
    )
    var p = FieldPieces()
    r.headers.write_to(p)
    assert_equal(len(p.ends), 20)
    var got = _pieces(r.headers)
    assert_equal(got[0], "x-user:admin")
    assert_equal(got[1], ": ")
    assert_equal(got[2], "v: w")
    assert_equal(got[3], "\r\n")
    assert_equal(got[5], ": ")
    assert_equal(got[6], "")
    # Two bytes that are not UTF-8 arrive as one two-byte piece.
    assert_equal(p.ends[10] - p.ends[9], 2)
    assert_equal(p.ends[14] - p.ends[13], 100_000)
    # Spaces and tabs around a value stay in its piece.
    assert_equal(got[16], "X-Space")
    assert_equal(got[18], " \t admin \t ")
    assert_true(pieces_match(p, 5))
    # The pieces are exactly `encode_to`'s bytes.
    var encoded = List[UInt8]()
    r.headers.encode_to(encoded)
    assert_equal(len(encoded), len(p.bytes))
    for i in range(len(encoded)):
        assert_equal(encoded[i], p.bytes[i])


def test_write_to_splits_fields_on_pinned_flare() raises:
    assert_true(write_to_splits_fields())
    assert_true(pieces_match(FieldPieces(), 0))


def test_comparison_tells_fields_apart() raises:
    # Joined as `name=value;`, these two would read the same.
    var a: List[Tuple[String, String]] = [
        (String("X"), String("1;Y=2")),
        (String("Z"), String("3")),
    ]
    var b: List[Tuple[String, String]] = [
        (String("X"), String("1")),
        (String("Y"), String("2;Z=3")),
    ]
    assert_not_equal(_mismatch(a, b), "")
    var swapped: List[Tuple[String, String]] = [a[1], a[0]]
    assert_not_equal(_mismatch(a, swapped), "")
    var cased: List[Tuple[String, String]] = [
        (String("x"), String("1;Y=2")),
        (String("Z"), String("3")),
    ]
    assert_not_equal(_mismatch(a, cased), "")
    assert_equal(_mismatch(a, a), "")


def test_rebuild_matches_the_adapter() raises:
    var many = List[Tuple[String, String]]()
    for i in range(4000):
        many.append((String("x-h") + String(i), String("v") + String(i)))
    var cases: List[List[Tuple[String, String]]] = [
        [
            (String("X-B"), String("2")),
            (String("Content-Type"), String("text/plain; q=1")),
            (String("x-b"), String("")),
            (String("X-Odd"), String("a: b\tc")),
            (String("X-Utf8"), String("é")),
            (String("X-Inner"), String("a \t b")),
        ],
        [
            (String("X"), String("1;Y=2")),
            (String("Z"), String("3")),
            (String("X"), String("1")),
            (String("Y"), String("2;Z=3")),
            (String("x"), String("=;")),
        ],
        [
            (String("X-A"), String("1")),
            (String("x-b"), String("2")),
            (String("x-A"), String("3")),
            (String("X-B"), String("4")),
            (String("x-a"), String("5")),
        ],
        many^,
    ]
    for c in cases:
        var r = _request(c)
        var got = rebuild_fields(r.headers)
        assert_true(Bool(got))
        assert_equal(_mismatch(_listed(got.value()), c), "")
        assert_equal(_mismatch(_listed(to_muntin_headers(r)), c), "")


def _refused(fields: List[Tuple[String, String]]) raises -> Bool:
    """Whether the prototype raises (the client's fault) on `fields`, and
    the adapter's `to_muntin_headers` raises too."""
    var r = _request(fields)
    var adapter_raised = False
    try:
        _ = to_muntin_headers(r)
    except:
        adapter_raised = True
    try:
        _ = rebuild_fields(r.headers)
    except:
        return adapter_raised
    return False


def test_rebuild_refuses_what_the_adapter_refuses() raises:
    assert_true(_refused([(String("x-user:admin"), String("zzz"))]))
    assert_true(
        _refused(
            [
                (String("x-user:admin"), String("zzz")),
                (String("x-user"), String("admin: zzz")),
            ]
        )
    )
    assert_true(_refused([(String("a:é"), String("v"))]))
    # Spaces or tabs around a value: Flare keeps them and `Headers` refuses
    # them, so a `write_to` that trimmed values would turn these into
    # fields the client did not send.
    assert_true(_refused([(String("x-sp"), String(" admin"))]))
    assert_true(_refused([(String("x-sp"), String("admin "))]))
    assert_true(_refused([(String("x-sp"), String("\tadmin"))]))
    assert_true(_refused([(String("x-sp"), String("admin\t"))]))
    assert_true(_refused([(String("x-sp"), String("  admin  "))]))
    assert_true(
        _refused([(String("x-ctl"), String("a") + chr(1) + String("b"))])
    )
    assert_true(_refused([(String("x-obs"), _octets([0x61, 0xFF]))]))
    assert_true(_refused([(_octets([0xFF]), String("v"))]))


def _synthetic(pieces: List[String]) -> FieldPieces:
    var p = FieldPieces()
    for s in pieces:
        p.write_string(s)
    return p^


def test_pieces_of_another_shape_are_the_servers_fault() raises:
    var ok: List[String] = ["X-A", ": ", "1", "\r\n"]
    assert_true(Bool(rebuild(_synthetic(ok), 1)))
    # One field written as one piece, as `write_to` could after a refactor.
    var joined: List[String] = ["X-A: 1\r\n"]
    assert_false(Bool(rebuild(_synthetic(joined), 1)))
    var few: List[String] = ["X-A", ": ", "1"]
    assert_false(Bool(rebuild(_synthetic(few), 1)))
    var more: List[String] = ["X-A", ": ", "1", "\r\n", "x"]
    assert_false(Bool(rebuild(_synthetic(more), 1)))
    var sep: List[String] = ["X-A", ":", "1", "\r\n"]
    assert_false(Bool(rebuild(_synthetic(sep), 1)))
    var crlf: List[String] = ["X-A", ": ", "1", "\n"]
    assert_false(Bool(rebuild(_synthetic(crlf), 1)))
    # A count that disagrees with `len()`.
    assert_false(Bool(rebuild(_synthetic(ok), 2)))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
