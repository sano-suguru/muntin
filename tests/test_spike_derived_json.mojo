# Spike for the derived JSON codecs decision (M3-082, issue #141), on the
# prototype only: `JsonFields` structs read and written from their fields.

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
    Request,
    Response,
    ToJson,
)
from muntin.testing import TestClient

comptime MADE = "MUNTIN_SPIKE_DERIVED_MADE"
comptime DROPPED = "MUNTIN_SPIKE_DERIVED_DROPPED"
comptime OUTER_DROPPED = "MUNTIN_SPIKE_DERIVED_OUTER_DROPPED"


def _count(name: StaticString) -> Int:
    var n = getenv(name)
    try:
        return Int(n) if n else 0
    except:
        return -1


def _bump(name: StaticString):
    _ = setenv(name, String(_count(name) + 1))


def _reset():
    for name in [MADE, DROPPED, OUTER_DROPPED]:
        _ = unsetenv(name)


def _text(r: Response) -> String:
    return String(unsafe_from_utf8=r.body)


def _post(mut app: App, path: String, body: String) raises -> Response:
    var h = Headers()
    h.add("Content-Type", "application/json")
    return app.handle(Request("POST", path, body, h^))


# The notes application's DTOs (bench/compare/notes), derived.


@fieldwise_init
struct Note(Copyable, JsonFields):
    var id: Int
    var owner: String
    var text: String
    var tag: String


@fieldwise_init
struct NewNote(JsonFields):
    var text: String
    var tag: String


def create_note(body: Json[NewNote]) -> Json[Note]:
    ref b = body.value
    return Json(Note(1, "ada", b.text, b.tag), status=201)


def list_notes() -> Json[List[Note]]:
    return Json(
        List[Note]([Note(1, "ada", "a", "x"), Note(2, "ada", "b", "y")])
    )


def test_notes_dtos_follow_their_fields() raises:
    var app = App()
    app.post["/notes"](create_note)
    app.get["/notes"](list_notes)
    var r = _post(app, "/notes", '{"text":"hi","tag":"t"}')
    assert_equal(r.status, 201)
    assert_equal(_text(r), '{"id":1,"owner":"ada","text":"hi","tag":"t"}')
    assert_equal(r.headers.get("content-type").or_else(""), "application/json")
    # The new field is required on the way in, as a hand-written reader's is.
    assert_equal(_post(app, "/notes", '{"text":"hi"}').status, 400)
    var l = TestClient(app).get("/notes")
    assert_equal(l.status, 200)
    assert_equal(
        _text(l),
        '[{"id":1,"owner":"ada","text":"a","tag":"x"},'
        + '{"id":2,"owner":"ada","text":"b","tag":"y"}]',
    )


# Every kind, against the hand-written writer of the same members.


@fieldwise_init
struct Address(Copyable, JsonFields):
    var city: String
    var zip: Int


@fieldwise_init
struct User(Copyable, JsonFields):
    var id: Int
    var name: String
    var admin: Bool
    var score: Float64
    var tags: List[String]
    var nickname: Optional[String]
    var home: Address
    var past: List[Address]
    var grid: List[List[Int]]
    var maybe: Optional[List[Address]]


def _hand(u: User) raises -> String:
    var out = JsonWriter()
    out.begin_object()
    out.field("id", u.id)
    out.field("name", u.name)
    out.field("admin", u.admin)
    out.field("score", u.score)
    out.field("tags", u.tags)
    out.field("nickname", u.nickname)
    out.name("home")
    out.begin_object()
    out.field("city", u.home.city)
    out.field("zip", u.home.zip)
    out.end_object()
    out.name("past")
    out.begin_array()
    for a in u.past:
        out.begin_object()
        out.field("city", a.city)
        out.field("zip", a.zip)
        out.end_object()
    out.end_array()
    out.name("grid")
    out.begin_array()
    for row in u.grid:
        out.value(row)
    out.end_array()
    out.name("maybe")
    if u.maybe:
        out.begin_array()
        for a in u.maybe.value():
            out.begin_object()
            out.field("city", a.city)
            out.field("zip", a.zip)
            out.end_object()
        out.end_array()
    else:
        out.null()
    out.end_object()
    return out^._finish()


def _derived(u: User) raises -> String:
    return _text(Json(u.copy()).to_response())


def test_every_kind_writes_as_written_by_hand() raises:
    var u = User(
        7,
        'A "q" é',
        True,
        2.5,
        ["a", "b"],
        None,
        Address("X", 1),
        [Address("Y", 2), Address("Z", 3)],
        [[1, 2], []],
        Optional[List[Address]]([Address("W", 4)]),
    )
    assert_equal(_derived(u), _hand(u))
    u.nickname = String("n")
    u.maybe = None
    assert_equal(_derived(u), _hand(u))


def test_every_kind_reads_back() raises:
    var text = (
        '{"id":7,"name":"A\\u00e9","admin":false,"score":1e2,"tags":[],'
        + '"home":{"city":"X","zip":1,"extra":[1]},"past":[{"city":"Y","zip":2}],'
        + '"grid":[[1],[2,3]],"maybe":null,"unknown":{}}'
    )
    var u = Json[User].from_body(text).take()
    assert_equal(u.id, 7)
    assert_equal(u.name, "Aé")
    assert_false(u.admin)
    assert_equal(u.score, 100.0)
    assert_equal(len(u.tags), 0)
    assert_false(Bool(u.nickname))
    assert_equal(u.home.zip, 1)
    assert_equal(u.past[0].city, "Y")
    assert_equal(u.grid[1][1], 3)
    assert_false(Bool(u.maybe))
    # Written back, then read again: the same text.
    var once = _derived(u)
    assert_equal(_derived(Json[User].from_body(once).take()), once)


def test_reading_failures() raises:
    var ok = (
        '"home":{"city":"X","zip":1},"past":[],"grid":[],'
        + '"tags":[],"id":1,"name":"n","admin":true,"score":0'
    )
    _ = Json[User].from_body("{" + ok + "}")
    var bad = List[String]()
    bad.append("[]")  # not an object
    bad.append("{" + ok.replace('"id":1', '"id":1.5') + "}")  # not an integer
    bad.append("{" + ok.replace('"id":1,', "") + "}")  # missing
    bad.append("{" + ok.replace('"tags":[]', '"tags":null') + "}")  # null list
    bad.append(
        "{" + ok.replace('"home":{"city":"X","zip":1}', '"home":[]') + "}"
    )
    bad.append("{" + ok.replace('"past":[]', '"past":[{"city":"Y"}]') + "}")
    bad.append("{" + ok + ',"nickname":3}')  # present, wrong kind
    for i in range(len(bad)):
        var raised = False
        try:
            _ = Json[User].from_body(bad[i])
        except:
            raised = True
        assert_true(raised, String(i))


# A hand-written type inside a derived one, and a direction taken over.


struct Token(FromJson, Movable, ToJson):
    """Move-only, hand-written, counted."""

    var text: String

    def __init__(out self, var text: String):
        self.text = text^
        _bump(MADE)

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        return Self(value.string())

    def write_json(self, mut out: JsonWriter) raises:
        out.string("<" + self.text + ">")

    def __deinit__(deinit self):
        _bump(DROPPED)


struct Session(JsonFields):
    """Never initialized by Muntin: `__init__` aborts."""

    var user: String
    var tokens: List[Token]
    var main: Token
    var spare: Optional[Token]
    var after: Int

    def __init__(out self):
        abort("a JsonFields struct's __init__ must not run")

    def __deinit__(deinit self):
        _bump(OUTER_DROPPED)


def _session(text: String) -> Bool:
    try:
        var s = Json[Session].from_body(text)
        assert_equal(len(s.value.tokens), 2)
        return True
    except:
        return False


def test_ownership_on_success_and_each_failure() raises:
    var long = String("x") * 64  # heap-allocated
    var good = (
        '{"user":"'
        + long
        + '","tokens":["a","b"],"main":"m","spare":"s","after":1}'
    )
    _reset()
    assert_true(_session(good))
    assert_equal(_count(MADE), 4)
    assert_equal(_count(DROPPED), 4)
    assert_equal(_count(OUTER_DROPPED), 1)
    # A failure at each later field: what was built is dropped once, the
    # struct's destructor never runs.
    var fails = List[String]()
    fails.append(
        '{"user":"' + long + '","tokens":["a",1],"main":"m","after":1}'
    )
    fails.append(
        '{"user":"' + long + '","tokens":["a","b"],"main":2,"after":1}'
    )
    fails.append(
        '{"user":"' + long + '","tokens":["a"],"main":"m","spare":[],"after":1}'
    )
    fails.append(
        '{"user":"' + long + '","tokens":["a"],"main":"m","after":"1"}'
    )
    var made = List[Int]()
    made.append(1)
    made.append(2)
    made.append(2)
    made.append(2)
    for i in range(len(fails)):
        _reset()
        assert_false(_session(fails[i]), String(i))
        assert_equal(_count(MADE), made[i], String(i))
        assert_equal(_count(DROPPED), made[i], String(i))
        assert_equal(_count(OUTER_DROPPED), 0, String(i))


@fieldwise_init
struct Shown(Copyable, JsonFields, ToJson):
    """Read from its fields, written by hand."""

    var city: String

    def write_json(self, mut out: JsonWriter) raises:
        out.string("custom:" + self.city)


@fieldwise_init
struct Outer(JsonFields):
    var shown: Shown
    var many: List[Shown]


def test_hand_written_direction_takes_over() raises:
    var o = (
        Json[Outer]
        .from_body('{"shown":{"city":"X"},"many":[{"city":"Y"}]}')
        .take()
    )
    assert_equal(
        _text(Json(o^).to_response()),
        '{"shown":"custom:X","many":["custom:Y"]}',
    )


@fieldwise_init
struct Stamp(JsonFields):
    var `created-at`: Int


def take_stamps(body: Json[List[Stamp]]) -> String:
    var total = 0
    for i in range(len(body.value)):
        total += body.value[i].`created-at`
    return String(total)


def test_backquoted_name_and_top_level_list_body() raises:
    var app = App()
    app.post["/stamps"](take_stamps)
    var r = _post(app, "/stamps", '[{"created-at":2},{"created-at":3}]')
    assert_equal(r.status, 200)
    assert_equal(_text(r), "5")
    assert_equal(_post(app, "/stamps", '{"created-at":2}').status, 400)
    assert_equal(_text(Json(Stamp(9)).to_response()), '{"created-at":9}')


struct Ping(JsonFields):
    """No field: `{}` with any members reads, and writes as `{}`."""

    def __init__(out self):
        pass

    def __deinit__(deinit self):
        _bump(OUTER_DROPPED)


def ping(body: Json[Ping]) -> Json[Ping]:
    return Json(Ping())


def test_struct_without_fields() raises:
    _reset()
    var app = App()
    app.post["/ping"](ping)
    var r = _post(app, "/ping", '{"anything":[1]}')
    assert_equal(r.status, 200)
    assert_equal(_text(r), "{}")
    assert_equal(_post(app, "/ping", "{}").status, 200)
    assert_equal(_post(app, "/ping", "[]").status, 400)
    assert_equal(_post(app, "/ping", "null").status, 400)
    # Two bodies read and two results written, each dropped once.
    assert_equal(_count(OUTER_DROPPED), 4)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
