"""The M3-002 inbound mapping rule, executed against pinned Flare (M3-002
evidence; runs only in the `flare` environment, from scripts/check_flare.sh).

Flare's `HeaderMap` has no public iterator, so an adapter rebuilds fields
from its public `encode_to` (`name: value\\r\\n` per field). Over HTTP/1.1
that parses back exactly: Flare's strict parser admits only token names.
Its HTTP/2 path (h2c, accepted by the default server) admits a name with
`:` after the first byte and control bytes in values, so a parse that
splits at the first colon could forge a field the client never sent
(`x-user:admin: zzz` read as `x-user` = `admin: zzz`). The rule therefore
verifies the parse against Flare's own by-name view: the parsed count is
`len()`, and per name the parsed values equal `get_all(name)` position by
position; then every field must pass Muntin's `Headers.add`. Any failure
means the request cannot be represented: the adapter answers 400.

`append` checks only CR/LF, so the h2 parser's output is reproduced here
in-process; `flare_header_probe.mojo` measures it over the wire.
"""

from std.collections import Optional
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from flare.http import Request as FlareRequest
from headers_spike import Headers, _same_name


def rebuild(request: FlareRequest) -> Optional[Headers]:
    """Muntin `Headers` with exactly Flare's fields, or `None` if the
    fields cannot be represented (the adapter then answers 400)."""
    var buf = List[UInt8]()
    request.headers.encode_to(buf)
    var text = String(from_utf8_lossy=Span(buf))
    var names = List[String]()
    var values = List[String]()
    for line in text.split("\r\n"):
        if line.byte_length() == 0:
            continue
        var colon = line.find(":")
        if colon <= 0:
            return None
        names.append(String(line[byte=:colon]))
        if line.byte_length() >= colon + 2:
            values.append(String(line[byte = colon + 2 :]))
        else:
            values.append(String())
    if len(names) != request.headers.len():
        return None
    var headers = Headers()
    for i in range(len(names)):
        var seen = 0
        for j in range(i):
            if _same_name(names[j], names[i]):
                seen += 1
        var flare_values = request.headers.get_all(names[i])
        if seen >= len(flare_values) or flare_values[seen] != values[i]:
            return None
        try:
            headers.add(names[i], values[i])
        except:
            return None
    return headers^


def _request(fields: List[Tuple[String, String]]) raises -> FlareRequest:
    var req = FlareRequest("GET", "/x")
    for f in fields:
        req.headers.append(f[0], f[1])
    return req^


def _fields(h: Headers) -> String:
    var out = String()
    for i in range(len(h)):
        out += h.name(i) + "=" + h.value(i) + ";"
    return out^


def test_http1_fields_rebuild_exactly() raises:
    var got = rebuild(
        _request(
            [
                (String("X-B"), String("2")),
                (String("Content-Type"), String("text/plain; q=1")),
                (String("x-b"), String("")),
                (String("X-Odd"), String("a: b\tc")),
                (String("X-Utf8"), String("é")),
            ]
        )
    )
    assert_true(Bool(got))
    assert_equal(
        _fields(got.value()),
        "X-B=2;Content-Type=text/plain; q=1;x-b=;X-Odd=a: b\tc;X-Utf8=é;",
    )
    assert_equal(len(rebuild(_request([])).value()), 0)


def test_forged_name_is_rejected() raises:
    # h2 lets `x-user:admin` through; a first-colon parse would read it
    # as `x-user`. Alone, or beside a real `x-user` with the same value.
    assert_false(
        Bool(rebuild(_request([(String("x-user:admin"), String("zzz"))])))
    )
    assert_false(
        Bool(
            rebuild(
                _request(
                    [
                        (String("x-user:admin"), String("zzz")),
                        (String("x-user"), String("admin: zzz")),
                    ]
                )
            )
        )
    )


def test_control_bytes_and_invalid_utf8_are_rejected() raises:
    assert_false(
        Bool(
            rebuild(
                _request(
                    [(String("x-ctl"), String("a") + chr(1) + String("b"))]
                )
            )
        )
    )
    var bad = List[UInt8]()
    bad.append(0x61)
    bad.append(0xFF)
    var invalid = String(unsafe_from_utf8=Span(bad))
    assert_false(Bool(rebuild(_request([(String("x-obs"), invalid)]))))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
