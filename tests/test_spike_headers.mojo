# M3-002 headers decision spike, application side. Decision and evidence:
# docs/ARCHITECTURE.md, "Headers decision (M3-002)".

from std.testing import assert_equal, assert_false, assert_raises
from std.testing import assert_true, TestSuite

from headers_spike import DictHeaders, HRequest, HResponse, Headers
from headers_spike import JoinedHeaders, UncheckedHeaders, box_raw
from headers_spike import raw_args, seam_check


def _fields(h: Headers) -> String:
    var out = String()
    for i in range(len(h)):
        out += h.name(i) + "=" + h.value(i) + ";"
    return out^


def test_order_casing_and_repeats_are_kept() raises:
    var h = Headers()
    h.add("X-B", "2")
    h.add("Content-Type", "text/plain")
    h.add("x-b", "3")
    h.add("Set-Cookie", "a=1; Expires=Wed, 21 Oct 2026 07:28:00 GMT")
    h.add("Set-Cookie", "b=2")
    assert_equal(len(h), 5)
    assert_equal(
        _fields(h),
        (
            "X-B=2;Content-Type=text/plain;x-b=3;Set-Cookie=a=1; Expires=Wed,"
            " 21 Oct 2026 07:28:00 GMT;Set-Cookie=b=2;"
        ),
    )


def test_lookup_is_ascii_case_insensitive() raises:
    var h = Headers()
    h.add("X-Signature", "abc")
    h.add("x-signature", "def")
    assert_equal(h.get("x-SIGNATURE").value(), "abc")
    var all = h.get_all("X-SIGNATURE")
    assert_equal(len(all), 2)
    assert_equal(all[1], "def")
    assert_false(Bool(h.get("X-Missing")))
    assert_equal(len(h.get_all("X-Missing")), 0)


def test_empty_value_is_present() raises:
    var h = Headers()
    h.add("X-Empty", "")
    assert_true(Bool(h.get("x-empty")))
    assert_equal(h.get("x-empty").value(), "")


def test_set_replaces_every_field_with_that_name() raises:
    var h = Headers()
    h.add("Vary", "a")
    h.add("X-Keep", "k")
    h.add("vary", "b")
    h.set("VARY", "c")
    assert_equal(_fields(h), "X-Keep=k;VARY=c;")


def test_invalid_names_and_values_are_rejected() raises:
    var h = Headers()
    with assert_raises(contains="invalid header name"):
        h.add("", "v")
    with assert_raises(contains="invalid header name"):
        h.add("X Space", "v")
    with assert_raises(contains="invalid header name"):
        h.add("X:Colon", "v")
    with assert_raises(contains="invalid header value"):
        h.add("X-Inject", "a\r\nSet-Cookie: evil=1")
    with assert_raises(contains="invalid header value"):
        h.add("X-Lf", "a\nb")
    with assert_raises(contains="invalid header value"):
        h.add("X-Nul", String("a") + chr(0) + "b")
    with assert_raises(contains="invalid header value"):
        h.set("X-Del", String("a") + chr(127))
    assert_equal(len(h), 0)
    # Accepted: HTAB, colons, quotes, and UTF-8 text.
    h.add("X-Ok", 'a\tb: "c" é')
    assert_equal(h.get("x-ok").value(), 'a\tb: "c" é')


def test_headers_copy_independently() raises:
    var a = Headers()
    a.add("X-A", "1")
    var b = a.copy()
    b.add("X-B", "2")
    assert_equal(len(a), 1)
    assert_equal(len(b), 2)


def test_request_and_response_defaults_add_nothing() raises:
    var req = HRequest("GET", "/x?y=1", "body")
    assert_equal(len(req.headers), 0)
    assert_equal(req.query, "y=1")
    var resp = HResponse.text("hi")
    assert_equal(len(resp.headers), 0)
    assert_equal(resp.status, 200)


def echo(var req: HRequest) -> HResponse:
    var resp = HResponse.text(
        req.method + " " + req.path + "?" + req.query + " " + req.body,
        status=202,
    )
    for i in range(len(req.headers)):
        try:
            resp.headers.add(req.headers.name(i), req.headers.value(i))
        except:
            pass
    return resp^


def test_raw_transport_is_lossless_through_erased() raises:
    # R1: the fields travel as extra raw argument strings through the
    # production `_Erased`; order, casing, repeats, empty values, colons
    # and tabs come back exactly.
    var h = Headers()
    h.add("X-B", "2")
    h.add("Content-Type", "text/plain; charset=utf-8")
    h.add("x-b", "")
    h.add("X-Odd", "a:b\tc")
    var boxed = box_raw(echo)
    var got = boxed.invoke(raw_args(HRequest("POST", "/hook?k=v", "data", h)))
    assert_equal(got.status, 202)
    assert_equal(
        got.body,
        (
            "POST /hook?k=v data|X-B=2|Content-Type=text/plain;"
            " charset=utf-8|x-b=|X-Odd=a:b\tc"
        ),
    )
    var none = boxed.invoke(raw_args(HRequest("GET", "/hook")))
    assert_equal(none.body, "GET /hook? ")
    assert_equal(len(raw_args(HRequest("GET", "/hook", "", h))), 4 + 2 * 4)


def test_candidate_b_loses_order_and_casing() raises:
    # A dictionary keyed by the lowercased name regroups repeated names and
    # forgets the original casing: the emitted order differs from the
    # received one.
    var d = DictHeaders()
    d.add("X-B", "2")
    d.add("Content-Type", "text/plain")
    d.add("x-b", "3")
    var flat = d.flatten()
    assert_equal(flat[0], "x-b: 2")
    assert_equal(flat[1], "x-b: 3")
    assert_equal(flat[2], "content-type: text/plain")


def test_candidate_c_breaks_set_cookie() raises:
    # Joining repeated fields with commas is RFC 9110's list rule, which
    # Set-Cookie does not follow: its values contain commas, so the two
    # cookies cannot be split back apart.
    var j = JoinedHeaders()
    j.add("Set-Cookie", "a=1; Expires=Wed, 21 Oct 2026 07:28:00 GMT")
    j.add("Set-Cookie", "b=2")
    var joined = j.get("set-cookie")
    assert_equal(joined, "a=1; Expires=Wed, 21 Oct 2026 07:28:00 GMT, b=2")
    assert_equal(len(joined.split(", ")), 3)


def located(h: UncheckedHeaders) -> Int:
    # V2's DX gain: a non-raising function (such as `to_response`) adds a
    # field without `try`; under V1 this needs `try` (headers_fail).
    var copy = UncheckedHeaders()
    for i in range(len(h.names)):
        copy.add(h.names[i], h.values[i])
    copy.add("X-Late", "a\r\nb")
    return seam_check(copy)


def test_candidate_v2_defers_the_error_to_the_seam() raises:
    # V2 accepts the invalid value where it is added; only the seam sees
    # it, as an index, after the handler returned.
    var h = UncheckedHeaders()
    h.add("X-Ok", "1")
    assert_equal(seam_check(h), -1)
    assert_equal(located(h), 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
