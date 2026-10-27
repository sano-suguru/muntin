# M3-098 prototype spike (evidence for its pull request, removed with the
# prototype): renamed and defaulted derived JSON members through `TestClient`,
# the member path and the schema following the member names, a default's
# ownership, and a hand-written `read` of a renamed struct.

from std.os import getenv, setenv, unsetenv
from std.testing import assert_equal, assert_true, TestSuite

from muntin import (
    App,
    Headers,
    Json,
    JsonCamelCase,
    JsonDefault,
    JsonFields,
    JsonMember,
    JsonMembers,
    JsonValue,
    JsonWriter,
    FromJson,
)
from muntin.testing import TestClient

comptime MADE = "MUNTIN_SPIKE_MADE"
comptime DROPPED = "MUNTIN_SPIKE_DROPPED"


def _count(name: StaticString) -> Int:
    var n = getenv(name)
    try:
        return Int(n) if n else 0
    except:
        return -1


def _bump(name: StaticString):
    _ = setenv(name, String(_count(name) + 1))


@fieldwise_init
struct Event(JsonCamelCase, JsonMembers):
    var event_id: Int
    var created_at: String
    var kind: String
    var tags: List[String]

    @staticmethod
    def json_members() -> List[JsonMember]:
        return [JsonMember("kind", name="type")]


@fieldwise_init
struct Query(JsonDefault, JsonMembers):
    var text: String
    var limit: Int
    var sort: Optional[String]
    var labels: List[String]

    @staticmethod
    def json_members() -> List[JsonMember]:
        return [
            JsonMember("limit", default=True),
            JsonMember("sort", default=True),
            JsonMember("labels", name="label-set", default=True),
        ]

    @staticmethod
    def json_default() -> Self:
        _bump(MADE)
        return Self("", 20, Optional[String]("new"), ["all"])


def echo_event(body: Json[Event]) -> Json[Event]:
    ref e = body.value
    return Json(Event(e.event_id + 1, e.created_at, e.kind, e.tags.copy()))


def search(body: Json[Query]) -> String:
    ref q = body.value
    var s = q.text + " " + String(q.limit) + " "
    s += q.sort.value() if q.sort else "-"
    for l in q.labels:
        s += " " + l
    return s


@fieldwise_init
struct Envelope(FromJson):
    var event: Event

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        return Self(value.read[Event]("evt"))


def envelope(body: Json[Envelope]) -> String:
    return body.value.event.kind + " " + body.value.event.created_at


def _raised[T: JsonFields](body: String) -> String:
    try:
        _ = Json[T].from_body(body)
        return "built"
    except e:
        return String(e)


def make_app() raises -> App:
    var app = App()
    app.post["/events"](echo_event)
    app.post["/search"](search)
    app.post["/envelopes"](envelope)
    return app^


def json_headers() raises -> Headers:
    var h = Headers()
    h.add("Content-Type", "application/json")
    return h^


def test_renamed_members_read_and_write() raises:
    var app = make_app()
    var c = TestClient(app)
    var r = c.post(
        "/events",
        '{"eventId":1,"createdAt":"now","type":"t","tags":["a"]}',
        headers=json_headers(),
    )
    assert_equal(r.status, 200)
    assert_equal(
        r.text(), '{"eventId":2,"createdAt":"now","type":"t","tags":["a"]}'
    )
    # The field's own name is not the member's.
    r = c.post(
        "/events",
        '{"event_id":1,"createdAt":"now","type":"t","tags":[]}',
        headers=json_headers(),
    )
    assert_equal(r.status, 400)
    assert_equal(
        _raised[Event]('{"event_id":1,"createdAt":"now","type":"t","tags":[]}'),
        "eventId: JSON member is missing",
    )
    r = c.post(
        "/envelopes",
        '{"evt":{"eventId":1,"createdAt":"now","type":7,"tags":[]}}',
        headers=json_headers(),
    )
    assert_equal(r.status, 400)
    try:
        _ = Json[Envelope].from_body(
            '{"evt":{"eventId":1,"createdAt":"now","type":7,"tags":[]}}'
        )
    except e:
        assert_equal(String(e), "evt.type: JSON value is not a string")
    r = c.post(
        "/envelopes",
        '{"evt":{"eventId":1,"createdAt":"now","type":"t","tags":[]}}',
        headers=json_headers(),
    )
    assert_equal(r.text(), "t now")


def test_defaulted_members() raises:
    var app = make_app()
    var c = TestClient(app)
    _ = unsetenv(MADE)
    var r = c.post("/search", '{"text":"q"}', headers=json_headers())
    assert_equal(r.text(), "q 20 new all")
    assert_equal(_count(MADE), 1)  # one default per read, not per member
    r = c.post(
        "/search",
        '{"text":"q","limit":3,"sort":null,"label-set":["x","y"]}',
        headers=json_headers(),
    )
    assert_equal(r.text(), "q 3 - x y")
    assert_equal(_count(MADE), 1)  # every defaulted member present: none
    r = c.post("/search", '{"limit":3}', headers=json_headers())
    assert_equal(r.status, 400)
    assert_equal(_raised[Query]('{"limit":3}'), "text: JSON member is missing")
    # A present `null` is not an absent member.
    assert_equal(
        _raised[Query]('{"text":"q","limit":null}'),
        "limit: JSON value is not a number",
    )
    # One default each for the three reads above that lack a defaulted member.
    assert_equal(_count(MADE), 4)


def _schema[T: JsonFields, reading: Bool]() raises -> String:
    var out = JsonWriter()
    Json[T]._schema[reading](out)
    return out^._finish()


def test_schema_follows_member_names() raises:
    assert_equal(
        _schema[Query, True](),
        '{"type":"object","properties":{"text":{"type":"string"},"limit":'
        + '{"type":"integer","format":"int64","minimum":-9223372036854775808,'
        + '"maximum":9223372036854775807},"sort":{"anyOf":[{"type":"string"},'
        + '{"type":"null"}]},"label-set":{"type":"array","items":{"type":'
        + '"string"}}},"required":["text"]}',
    )
    assert_true(
        _schema[Event, False]().endswith(
            '"required":["eventId","createdAt","type","tags"],'
            + '"additionalProperties":false}'
        )
    )


@fieldwise_init
struct Widths(JsonFields):
    var a: Int8
    var b: Int16
    var c: Int32
    var d: Int64
    var e: UInt8
    var f: UInt16
    var g: UInt32
    var h: UInt64
    var x: Float32
    var many: List[UInt8]
    var maybe: Optional[Float32]


def test_widths_read_and_write() raises:
    var text = (
        '{"a":-128,"b":32767,"c":-2147483648,"d":-9223372036854775808,'
        + '"e":255,"f":65535,"g":4294967295,"h":18446744073709551615,'
        + '"x":0.1,"many":[0,7],"maybe":null}'
    )
    var w = Json[Widths].from_body(text).take()
    assert_equal(w.h, UInt64.MAX)
    assert_equal(w.x, Float32(0.1))
    assert_equal(Json(w^).to_response().text(), text)
    assert_equal(
        _raised[Widths](text.replace('"a":-128', '"a":-129')),
        "a: JSON number is out of Int8 range",
    )
    assert_equal(
        _raised[Widths](
            text.replace('"h":18446744073709551615', '"h":18446744073709551616')
        ),
        "h: JSON number is out of UInt64 range",
    )
    assert_equal(
        _raised[Widths](text.replace('"e":255', '"e":-1')),
        "e: JSON number is out of UInt8 range",
    )
    assert_equal(
        _raised[Widths](text.replace('"x":0.1', '"x":1e39')),
        "x: JSON number is out of Float32 range",
    )
    assert_equal(
        _raised[Widths](text.replace('"many":[0,7]', '"many":[0,256]')),
        "many[1]: JSON number is out of UInt8 range",
    )
    assert_equal(
        _raised[Widths](text.replace('"x":0.1', '"x":3.4028235677973366e38')),
        "x: JSON number is out of Float32 range",
    )
    var schema = _schema[Widths, True]()
    assert_true(
        schema.startswith(
            '{"type":"object","properties":{"a":{"type":"integer","minimum":'
            + '-128,"maximum":127},'
        ),
        schema,
    )
    assert_true(
        '"h":{"type":"integer","minimum":0,"maximum":18446744073709551615}'
        in schema,
        schema,
    )
    assert_true('"x":{"type":"number","format":"float"}' in schema, schema)


struct Counted(Copyable, FromJson):
    """Counts each value made (built, read or copied) and each dropped."""

    var v: String

    def __init__(out self, v: String):
        self.v = v
        _bump(MADE)

    def __init__(out self, *, copy: Self):
        self.v = copy.v
        _bump(MADE)

    def __deinit__(deinit self):
        _bump(DROPPED)

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        return Self(value.string())


@fieldwise_init
struct Held(JsonDefault, JsonMembers):
    var first: Counted
    var second: Counted
    var last: Int

    @staticmethod
    def json_members() -> List[JsonMember]:
        return [JsonMember("second", default=True)]

    @staticmethod
    def json_default() -> Self:
        return Self(Counted("d1"), Counted("d2"), 0)


def test_default_ownership() raises:
    var long = String("z") * 64
    var cases = List[String]()
    cases.append('{"first":"' + long + '","last":1}')  # defaulted, built
    cases.append('{"first":"' + long + '"}')  # defaulted, then fails
    cases.append('{"first":"' + long + '","second":"s","last":1}')
    cases.append('{"first":"' + long + '","second":"s"}')  # fails at last
    cases.append('{"first":1}')  # fails before the default is used
    for i in range(len(cases)):
        _ = unsetenv(MADE)
        _ = unsetenv(DROPPED)
        _ = _raised[Held](cases[i])
        assert_true(_count(MADE) > 0, String(i))
        assert_equal(_count(MADE), _count(DROPPED), String(i))


@fieldwise_init
struct Odd(JsonCamelCase):
    var _id: Int
    var a__b: Int
    var x_1: Int
    var tail_: Int
    var url_path: Int


def test_camel_case_edges() raises:
    var text = '{"_id":1,"a_B":2,"x_1":3,"tail_":4,"urlPath":5}'
    var o = Json[Odd].from_body(text).take()
    assert_equal(o.url_path, 5)
    assert_equal(Json(o^).to_response().text(), text)


@fieldwise_init
struct Outer(JsonFields):
    var many: List[Query]
    var maybe: Optional[Query]


@fieldwise_init
struct Picks(FromJson):
    var a: UInt8
    var b: Float32
    var q: Query

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        return Self(
            value.read[UInt8]("a"),
            value["b"].read[Float32](),
            value.read[Query]("q"),
        )


def test_nested_defaults_and_hand_written_reads() raises:
    var o = (
        Json[Outer]
        .from_body(
            '{"many":[{"text":"a"},{"text":"b","limit":1}],"maybe":{"text":"c"}}'
        )
        .take()
    )
    assert_equal(o.many[0].limit, 20)
    assert_equal(o.many[1].limit, 1)
    assert_equal(o.maybe.value().labels[0], "all")
    var p = Json[Picks].from_body('{"a":7,"b":0.5,"q":{"text":"t"}}').take()
    assert_equal(p.a, 7)
    assert_equal(p.q.limit, 20)
    try:
        _ = Json[Picks].from_body('{"a":256,"b":0.5,"q":{"text":"t"}}')
        assert_true(False)
    except e:
        assert_equal(String(e), "a: JSON number is out of UInt8 range")


@fieldwise_init
struct Mid(JsonFields):
    var b: Int16
    var c: Int32
    var f: UInt16
    var g: UInt32
    var u: UInt
    var d: Int64
    var a: Int8
    var x: Float32


def test_width_boundaries() raises:
    var ok = (
        '{"b":-32768,"c":2147483647,"f":0,"g":4294967295,'
        + '"u":18446744073709551615,"d":9223372036854775807,"a":127,"x":-0.0}'
    )
    _ = Json[Mid].from_body(ok)
    var bad = List[String]()
    var why = List[String]()
    bad.append(ok.replace('"b":-32768', '"b":-32769'))
    why.append("b: JSON number is out of Int16 range")
    bad.append(ok.replace('"c":2147483647', '"c":2147483648'))
    why.append("c: JSON number is out of Int32 range")
    bad.append(ok.replace('"f":0', '"f":-1'))
    why.append("f: JSON number is out of UInt16 range")
    bad.append(ok.replace('"g":4294967295', '"g":4294967296'))
    why.append("g: JSON number is out of UInt32 range")
    bad.append(ok.replace('"u":18446744073709551615', '"u":-1'))
    why.append("u: JSON number is out of UInt range")
    bad.append(ok.replace('"d":9223372036854775807', '"d":9223372036854775808'))
    why.append("d: JSON number is out of Int64 range")
    bad.append(ok.replace('"a":127', '"a":100000000000000000000'))
    why.append("a: JSON number is out of Int8 range")
    bad.append(ok.replace('"a":127', '"a":1.0'))
    why.append("a: JSON number is not an integer")
    bad.append(ok.replace('"x":-0.0', '"x":1e400'))
    why.append("x: JSON number is out of Float32 range")
    bad.append(ok.replace('"x":-0.0', '"x":"1"'))
    why.append("x: JSON value is not a number")
    for i in range(len(bad)):
        assert_equal(_raised[Mid](bad[i]), why[i], String(i))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
