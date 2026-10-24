# Spike of M3-087 (prototype only, removed before the decision merges):
# derived JSON values inside hand-written codecs. A hand-written
# `write_json` writes a `JsonFields` struct, an `Optional` or a `List` of
# one through `out.field` and `out.value`, the same text `Json[T]` writes;
# a hand-written `from_json` reads one through `JsonValue.read[T]()` and
# `read[T](name)`, with the derived member path, through a typed route; a
# type that is both `JsonFields` and `ToJson` keeps its own writer; and
# ownership on success and on a failure inside and after a read.

from std.os import abort, getenv, setenv, unsetenv
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from muntin import (
    App,
    FromJson,
    Headers,
    Json,
    JsonFields,
    JsonValue,
    JsonWriter,
    Rejection,
    Request,
    Response,
    ToJson,
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
    for name in [MADE, DROPPED]:
        _ = unsetenv(name)


def _headers() raises -> Headers:
    var h = Headers()
    h.add("Content-Type", "application/json")
    return h^


@fieldwise_init
struct Place(Copyable, JsonFields):
    var city: String
    var zip: Optional[Int]
    var tags: List[String]


@fieldwise_init
struct Shown(Copyable, JsonFields, ToJson):
    """Both: its own writer takes over inside a hand-written one too."""

    var n: Int

    def write_json(self, mut out: JsonWriter) raises:
        out.string("shown " + String(self.n))


@fieldwise_init
struct Envelope(Copyable, FromJson, ToJson):
    """One special member (`version`, checked and renamed), the rest
    derived: what a type needed every nested DTO written by hand for."""

    var version: Int
    var place: Place
    var spare: Optional[Place]
    var trail: List[Place]
    var shown: Shown

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        var v = value["v"].int()
        if v != 2:
            raise Error("unsupported version")
        return Self(
            v,
            value.read[Place]("place"),
            value.read[Optional[Place]]("spare"),
            value.read[List[Place]]("trail"),
            Shown(value.read[Int]("shown")),
        )

    def write_json(self, mut out: JsonWriter) raises:
        out.begin_object()
        out.field("v", self.version)
        out.field("place", self.place)
        out.field("spare", self.spare)
        out.field("trail", self.trail)
        out.field("shown", self.shown)
        out.name("again")
        out.begin_array()
        out.value(self.place)
        out.value(self.spare)
        out.value(self.trail)
        out.end_array()
        out.end_object()


@fieldwise_init
struct Holder(JsonFields):
    """A derived parent of a hand-written member."""

    var label: String
    var env: Envelope


def echo(body: Json[Envelope]) -> Json[Envelope]:
    return Json(body.value.copy())


def hold(body: Json[Holder]) -> String:
    return body.value.env.place.city


def make_app() -> App:
    var app = App()
    app.post["/env"](echo)
    app.post["/hold"](hold)
    return app^


comptime PLACE = '{"city":"X","zip":1,"tags":["a"]}'
comptime GOOD = (
    '{"v":2,"place":'
    + PLACE
    + ',"trail":['
    + PLACE
    + ',{"city":"Y","zip":null,"tags":[]}],"shown":3}'
)


def test_hand_written_writer_writes_derived_values() raises:
    var app = make_app()
    var c = TestClient(app)
    var r = c.post("/env", GOOD, headers=_headers())
    assert_equal(r.status, 200)
    var p = '{"city":"X","zip":1,"tags":["a"]}'
    var y = '{"city":"Y","zip":null,"tags":[]}'
    assert_equal(
        r.text(),
        '{"v":2,"place":'
        + p
        + ',"spare":null,"trail":['
        + p
        + ","
        + y
        + '],"shown":"shown 3","again":['
        + p
        + ",null,["
        + p
        + ","
        + y
        + "]]}",
    )
    # The same text `Json[T]` writes for the member's type.
    var alone = Json(Place("X", Optional[Int](1), ["a"])).to_response()
    assert_equal(String(unsafe_from_utf8=alone.body), p)


struct Nested(ToJson):
    """Kinds a derived field takes beyond a struct and one `List` or
    `Optional` of it, which M3-075's fixtures pinned as unwritable
    (`field_list_of_lists`, `field_list_of_optionals`,
    `field_optional_of_list`): written through the same rules."""

    var grid: List[List[Place]]
    var maybe: Optional[List[Place]]
    var shown: List[Shown]
    var ints: List[List[Int]]
    var marks: List[Optional[Int]]
    var tags: Optional[List[Int]]

    def __init__(out self):
        self.grid = [[Place("X", None, [])]]
        self.maybe = Optional[List[Place]](List[Place]())
        self.shown = [Shown(1), Shown(2)]
        self.ints = [[1, 2], []]
        self.marks = [Optional[Int](1), None]
        self.tags = Optional[List[Int]]([3])

    def write_json(self, mut out: JsonWriter) raises:
        out.begin_object()
        out.field("grid", self.grid)
        out.field("maybe", self.maybe)
        out.field("shown", self.shown)
        out.field("ints", self.ints)
        out.field("marks", self.marks)
        out.field("tags", self.tags)
        out.end_object()


def test_every_derived_kind_through_the_writer() raises:
    var r = Json(Nested()).to_response()
    assert_equal(
        String(unsafe_from_utf8=r.body),
        '{"grid":[[{"city":"X","zip":null,"tags":[]}]],"maybe":[],'
        + '"shown":["shown 1","shown 2"],"ints":[[1,2],[]],'
        + '"marks":[1,null],"tags":[3]}',
    )


def _expect(r: Response, message: String) raises:
    assert_equal(r.status, 400)
    var rej = r.rejection()
    assert_true(Bool(rej), message)
    assert_equal(rej.value().step, Rejection.FROM_JSON)
    assert_equal(rej.value().message, message)


def test_hand_written_reader_keeps_the_member_path() raises:
    var app = make_app()
    var c = TestClient(app)
    _expect(
        c.post(
            "/env",
            String(GOOD).replace('"city":"X"', '"city":1'),
            headers=_headers(),
        ),
        "place.city: JSON value is not a string",
    )
    _expect(
        c.post("/env", '{"v":2,"trail":[],"shown":1}', headers=_headers()),
        "place: JSON member is missing",
    )
    _expect(
        c.post(
            "/env",
            String(GOOD).replace('"tags":[]', '"tags":[true]'),
            headers=_headers(),
        ),
        "trail[1].tags[0]: JSON value is not a string",
    )
    _expect(
        c.post(
            "/env",
            String(GOOD).replace('"shown":3', '"shown":"3"'),
            headers=_headers(),
        ),
        "shown: JSON value is not a number",
    )
    _expect(
        c.post(
            "/env", String(GOOD).replace('"v":2', '"v":1'), headers=_headers()
        ),
        "unsupported version",
    )
    # Under a derived parent, the parent's path, then the hand-written
    # reader's message, which starts with its own path.
    assert_equal(
        c.post(
            "/hold", '{"label":"l","env":' + GOOD + "}", headers=_headers()
        ).text(),
        "X",
    )
    _expect(
        c.post(
            "/hold",
            '{"label":"l","env":'
            + String(GOOD).replace('"city":"X"', '"city":1')
            + "}",
            headers=_headers(),
        ),
        "env: place.city: JSON value is not a string",
    )
    # `read[T]()`: the path below the value itself.
    var raised = String()
    try:
        var v = _parse('{"city":"X","tags":[1]}')
        _ = v.read[Place]()
    except e:
        raised = String(e)
    assert_equal(raised, "tags[0]: JSON value is not a string")


def _parse(text: String) raises -> JsonValue:
    """A `JsonValue` from text, through a hand-written reader."""
    var k = Json[Keep].from_body(text).take()
    return k.value.copy()


struct Keep(FromJson, Movable):
    var value: JsonValue

    def __init__(out self, value: JsonValue):
        self.value = value.copy()

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        return Self(value)


struct Token(FromJson, Movable):
    """Move-only, hand-written, counted."""

    var text: String

    def __init__(out self, var text: String):
        self.text = text^
        _bump(MADE)

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        return Self(value.string())

    def __deinit__(deinit self):
        _bump(DROPPED)


struct Wallet(JsonFields):
    """Never initialized by Muntin: `__init__` aborts."""

    var owner: String
    var tokens: List[Token]
    var count: Int

    def __init__(out self):
        abort("a JsonFields struct's __init__ must not run")


struct Purse(FromJson, Movable):
    var wallet: Wallet
    var after: Int

    def __init__(out self, var wallet: Wallet, after: Int):
        self.wallet = wallet^
        self.after = after

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        var w = value.read[Wallet]("wallet")
        return Self(w^, value["after"].int())


def _purse(text: String) -> String:
    try:
        var p = Json[Purse].from_body(text)
        assert_equal(len(p.value.wallet.tokens), 2)
        return "ok"
    except e:
        return String(e)


def test_ownership_inside_and_after_a_read() raises:
    var long = String("x") * 64  # heap-allocated
    var w = '{"owner":"' + long + '","tokens":["a","b"],"count":1}'
    _reset()
    assert_equal(_purse('{"wallet":' + w + ',"after":1}'), "ok")
    assert_equal(_count(MADE), 2)
    assert_equal(_count(DROPPED), 2)
    # A failure inside the read: the built tokens dropped once.
    _reset()
    assert_equal(
        _purse('{"wallet":' + w.replace('"count":1', '"count":"1"') + "}"),
        "wallet.count: JSON value is not a number",
    )
    assert_equal(_count(MADE), 2)
    assert_equal(_count(DROPPED), 2)
    # A failure after it: the read wallet dropped once, by the application.
    _reset()
    assert_equal(
        _purse('{"wallet":' + w + "}"), 'JSON member "after" is missing'
    )
    assert_equal(_count(MADE), 2)
    assert_equal(_count(DROPPED), 2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
