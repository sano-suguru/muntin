# M3-098 prototype spike (evidence for its pull request, removed with the
# prototype): renamed and defaulted derived JSON members through `TestClient`;
# a default read from its JSON text by the field's own rules, with no value
# for the required members; the member path and the schema following the
# member names, non-ASCII ones included; counted move-only values dropped once around defaulted
# members; `[]` and `null` defaults for a hand-written type; a hand-written
# `read` of a renamed and defaulted struct.

from std.os import getenv, setenv, unsetenv
from std.testing import assert_equal, assert_true, TestSuite

from muntin import (
    App,
    FromJson,
    Headers,
    Json,
    JsonCamelCase,
    JsonFields,
    JsonMember,
    JsonMembers,
    JsonValue,
    JsonWriter,
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


def _reset():
    _ = unsetenv(MADE)
    _ = unsetenv(DROPPED)


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
struct Query(JsonMembers):
    """Required `text` needs no placeholder: only the defaulted members
    carry a value."""

    var text: String
    var limit: Int
    var sort: Optional[String]
    var labels: List[String]

    @staticmethod
    def json_members() -> List[JsonMember]:
        return [
            JsonMember("limit", default="20"),
            JsonMember("sort", default='"new"'),
            JsonMember("labels", name="label-set", default='["all"]'),
        ]


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
    var query: Query

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        return Self(value.read[Event]("evt"), value.read[Query]("q"))


def envelope(body: Json[Envelope]) -> String:
    ref v = body.value
    return v.event.kind + " " + v.event.created_at + " " + String(v.query.limit)


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
    var by_field = '{"event_id":1,"createdAt":"now","type":"t","tags":[]}'
    assert_equal(
        c.post("/events", by_field, headers=json_headers()).status, 400
    )
    assert_equal(_raised[Event](by_field), "eventId: JSON member is missing")
    assert_equal(
        _raised[Event]('{"eventId":1,"createdAt":"now","kind":"t","tags":[]}'),
        "type: JSON member is missing",
    )
    # Inside a hand-written reader, the path uses the member names.
    var bad = (
        '{"evt":{"eventId":1,"createdAt":"now","type":7,"tags":[]},"q":{}}'
    )
    assert_equal(c.post("/envelopes", bad, headers=json_headers()).status, 400)
    try:
        _ = Json[Envelope].from_body(bad)
        assert_true(False)
    except e:
        assert_equal(String(e), "evt.type: JSON value is not a string")
    var ok = (
        '{"evt":{"eventId":1,"createdAt":"now","type":"t","tags":[]},'
        + '"q":{"text":"x"}}'
    )
    assert_equal(
        c.post("/envelopes", ok, headers=json_headers()).text(), "t now 20"
    )


def test_defaulted_members() raises:
    var app = make_app()
    var c = TestClient(app)
    var r = c.post("/search", '{"text":"q"}', headers=json_headers())
    assert_equal(r.text(), "q 20 new all")
    r = c.post(
        "/search",
        '{"text":"q","limit":3,"sort":null,"label-set":["x","y"]}',
        headers=json_headers(),
    )
    # A present `null` is not absent: an `Optional` reads it as empty.
    assert_equal(r.text(), "q 3 - x y")
    # The field's own name is not the member's: `labels` is unknown, ignored.
    r = c.post("/search", '{"text":"q","labels":["z"]}', headers=json_headers())
    assert_equal(r.text(), "q 20 new all")
    # A required member stays required.
    assert_equal(
        c.post("/search", '{"limit":3}', headers=json_headers()).status, 400
    )
    assert_equal(_raised[Query]('{"limit":3}'), "text: JSON member is missing")
    # A present `null` for a non-Optional defaulted member is a failure.
    assert_equal(
        _raised[Query]('{"text":"q","limit":null}'),
        "limit: JSON value is not a number",
    )


def test_each_read_gets_its_own_default() raises:
    var a = Json[Query].from_body('{"text":"a"}').take()
    var b = Json[Query].from_body('{"text":"b"}').take()
    a.labels.append("more")
    assert_equal(len(a.labels), 2)
    assert_equal(len(b.labels), 1)


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
        _schema[Query, False]().endswith(
            '"required":["text","limit","sort","label-set"],'
            + '"additionalProperties":false}'
        )
    )
    assert_true(
        _schema[Event, False]().endswith(
            '"required":["eventId","createdAt","type","tags"],'
            + '"additionalProperties":false}'
        )
    )


struct Token(FromJson, Movable):
    """Move-only, counted: each value made (read) and each dropped."""

    var v: String

    def __init__(out self, v: String):
        self.v = v
        _bump(MADE)

    def __deinit__(deinit self):
        _bump(DROPPED)

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        return Self(value.string())


@fieldwise_init
struct Place(JsonMembers):
    """A nested struct with its own default."""

    var city: String
    var country: String

    @staticmethod
    def json_members() -> List[JsonMember]:
        return [JsonMember("country", default='"JP"')]


@fieldwise_init
struct Held(JsonMembers):
    """Counted fields around defaulted members, one of them a list of a
    move-only hand-written type."""

    var first: Token
    var place: Place
    var tags: List[String]
    var more: List[Token]
    var maybe: Optional[Token]
    var second: Token
    var last: Int

    @staticmethod
    def json_members() -> List[JsonMember]:
        return [
            JsonMember("tags", default='["a","b"]'),
            JsonMember("more", default="[]"),
            JsonMember("maybe", default="null"),
        ]


def test_move_only_and_nested_defaults_and_ownership() raises:
    var h = (
        Json[Held]
        .from_body(
            '{"first":"a","place":{"city":"Kyoto"},"second":"b","last":1}'
        )
        .take()
    )
    assert_equal(h.place.city, "Kyoto")
    assert_equal(h.place.country, "JP")
    assert_equal(len(h.tags), 2)
    assert_equal(len(h.more), 0)
    assert_true(not h.maybe)
    _ = h^
    var long = String("z") * 64
    var at = '{"first":"' + long + '","place":{"city":"K"},'
    var cases = List[String]()
    var made = List[Int]()
    # Defaulted, built.
    cases.append(at + '"second":"s","last":1}')
    made.append(2)
    # Present instead of defaulted, built.
    cases.append(at + '"more":["x","y"],"maybe":"m","second":"s","last":1}')
    made.append(5)
    # Defaulted, then fails at `second` and at `last`.
    cases.append(at + '"last":1}')
    made.append(1)
    cases.append(at + '"second":"s"}')
    made.append(2)
    # Fails inside a present list, after one element.
    cases.append(at + '"more":["x",1],"second":"s","last":1}')
    made.append(2)
    # Fails before any default.
    cases.append('{"first":1}')
    made.append(0)
    for i in range(len(cases)):
        _reset()
        _ = _raised[Held](cases[i])
        assert_equal(_count(MADE), made[i], String(i))
        assert_equal(_count(DROPPED), made[i], String(i))


@fieldwise_init
struct Odd(JsonCamelCase, JsonMembers):
    var _id: Int
    var a__b: Int
    var x_1: Int
    var tail_: Int
    var url_path: Int
    var user_id: Int

    @staticmethod
    def json_members() -> List[JsonMember]:
        # A rename wins over the camelCase rule.
        return [JsonMember("user_id", name="uid")]


def test_camel_case_edges_and_rename_precedence() raises:
    var text = '{"_id":1,"a_B":2,"x_1":3,"tail_":4,"urlPath":5,"uid":6}'
    var o = Json[Odd].from_body(text).take()
    assert_equal(o.url_path, 5)
    assert_equal(o.user_id, 6)
    assert_equal(Json(o^).to_response().text(), text)


@fieldwise_init
struct Shop(JsonCamelCase, JsonMembers):
    """Non-ASCII field and member names: camelCase keeps every byte that is
    not an `_` it removes or a letter it uppercases."""

    var `café_name`: String
    var `日本_語`: Int
    var `größe_x`: Int
    var plain_id: Int

    @staticmethod
    def json_members() -> List[JsonMember]:
        return [JsonMember("plain_id", name="ид", default="7")]


def test_non_ascii_names_read_write_and_schema() raises:
    var text = '{"caféName":"x","日本_語":2,"größeX":3}'
    var shop = Json[Shop].from_body(text).take()
    assert_equal(shop.`café_name`, "x")
    assert_equal(shop.`日本_語`, 2)
    assert_equal(shop.`größe_x`, 3)
    assert_equal(shop.plain_id, 7)
    assert_equal(
        Json(shop^).to_response().text(),
        '{"caféName":"x","日本_語":2,"größeX":3,"ид":7}',
    )
    # The bytes of `é` read one by one as Latin-1 are another name.
    assert_equal(
        _raised[Shop]('{"cafÃ©Name":"x","日本_語":2,"größeX":3}'),
        "caféName: JSON member is missing",
    )
    assert_true(
        _schema[Shop, True]().endswith(
            '"required":["caféName","日本_語","größeX"]}'
        )
    )
    assert_true(
        _schema[Shop, False]().endswith(
            '"required":["caféName","日本_語","größeX","ид"],'
            + '"additionalProperties":false}'
        )
    )


@fieldwise_init
struct Outer(JsonFields):
    var many: List[Query]
    var maybe: Optional[Query]


def test_defaults_inside_lists_and_optionals() raises:
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
    assert_equal(
        _raised[Outer]('{"many":[{"text":"a"},{"limit":1}]}'),
        "many[1].text: JSON member is missing",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
