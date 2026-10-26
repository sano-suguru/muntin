# Derived JSON codecs (M3-083): `JsonFields` structs read and written from
# their fields through `Json[T]`, as a body, a result and a top-level `List`
# or `Optional`; every field kind against the hand-written writer; each
# reading failure, with the `Rejection` step and member path a typed route
# reports for a bare, carried and guarded body; ownership on success and on
# a failure at each field (`__init__` never runs, each built field dropped
# once); a hand-written direction taking over; derived values read and
# written inside hand-written codecs (M3-087). Contract: the "Next
# production slice" of docs/history/decisions/m3-082-derived-json-codecs-decision.md
# and of m3-087-derived-json-in-hand-written-codecs-decision.md; semantics:
# docs/reference/bodies.md. The refusals at registration:
# tests/json_api_fail/derived_*.mojo; at a hand-written codec's call:
# tests/json_api_fail/hand_written_derived_*.mojo. Over loopback:
# adapters/flare/test_localhost_roundtrip.mojo.

from std.os import abort, getenv, setenv, unsetenv
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from muntin import (
    App,
    FromJson,
    Group,
    Headers,
    Json,
    JsonFields,
    JsonValue,
    JsonWriter,
    Rejection,
    Request,
    Response,
    State,
    ToErrorResponse,
    ToJson,
    WithHeaders,
)
from muntin.testing import TestClient

comptime MADE = "MUNTIN_DERIVED_MADE"
comptime DROPPED = "MUNTIN_DERIVED_DROPPED"
comptime OUTER_DROPPED = "MUNTIN_DERIVED_OUTER_DROPPED"


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


struct Wallet(JsonFields):
    """A nested struct holding a counted token and a heap string, failing at
    its last field: each built field is dropped once, inside and out."""

    var owner: String
    var token: Token
    var count: Int


struct Pocket(JsonFields):
    var label: String
    var wallet: Wallet
    var after: Int


def test_ownership_on_a_nested_failure() raises:
    var long = String("y") * 64  # heap-allocated
    _reset()
    var raised = String()
    try:
        _ = Json[Pocket].from_body(
            '{"label":"'
            + long
            + '","wallet":{"owner":"'
            + long
            + '","token":"t","count":"x"},"after":1}'
        )
    except e:
        raised = String(e)
    assert_equal(raised, "wallet.count: JSON value is not a number")
    assert_equal(_count(MADE), 1)
    assert_equal(_count(DROPPED), 1)
    _reset()
    var ok = Json[Pocket].from_body(
        '{"label":"a","wallet":{"owner":"b","token":"t","count":2},"after":1}'
    )
    assert_equal(ok.value.wallet.count, 2)
    _ = ok^
    assert_equal(_count(MADE), 1)
    assert_equal(_count(DROPPED), 1)


@fieldwise_init
struct Shown(Copyable, JsonFields, ToJson):
    """Read from its fields, written by hand."""

    var city: String

    def write_json(self, mut out: JsonWriter) raises:
        out.string("custom:" + self.city)


@fieldwise_init
struct Upper(Copyable, FromJson, JsonFields):
    """Written from its fields, read by hand."""

    var city: String

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        return Self(value.string().upper())


@fieldwise_init
struct Outer(JsonFields):
    var shown: Shown
    var many: List[Shown]
    var upper: Upper


def test_hand_written_direction_takes_over() raises:
    var o = (
        Json[Outer]
        .from_body('{"shown":{"city":"X"},"many":[{"city":"Y"}],"upper":"z"}')
        .take()
    )
    assert_equal(o.upper.city, "Z")
    assert_equal(
        _text(Json(o^).to_response()),
        '{"shown":"custom:X","many":["custom:Y"],"upper":{"city":"Z"}}',
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


# What a typed route reports when a derived body cannot be read (M3-084):
# not JSON is `Rejection.JSON` with the parser's message; any later failure
# is `Rejection.FROM_JSON`, its message prefixed with the member path.


@fieldwise_init
struct Board(JsonFields):
    var title: String
    var notes: List[NewNote]
    var pinned: Optional[NewNote]


def post_board(body: Json[Board]) -> String:
    return String(body.value.title, " ", len(body.value.notes))


def post_users(body: Json[List[User]]) -> String:
    return String(len(body.value))


def post_maybe(body: Json[Optional[NewNote]]) -> String:
    if body.value:
        return "note " + body.value.value().text
    return "none"


def post_session(body: Json[Session]) -> String:
    return body.value.user


def post_carried(body: WithHeaders[Json[Board]]) -> String:
    return String(body.body.value.title, " ", len(body.headers))


@fieldwise_init
struct Denied(Movable, ToErrorResponse):
    def to_error_response(var self) -> Response:
        return Response.text("Unauthorized", status=401)


@fieldwise_init
struct Who(Movable):
    var name: String


def check_key(keys: State[String], headers: Headers) raises Denied -> Who:
    if headers.get("x-key").or_else("") != keys[]:
        raise Denied()
    return Who("ada")


def guarded_board(who: Who, id: Int, body: Json[Board]) -> String:
    return String(who.name, " ", id, " ", body.value.title)


def put_board(boards: State[String], id: Int, var body: Json[Board]) -> String:
    return String(id, " ", body^.take().title, " ", boards[])


def make_app() -> App:
    var app = App()
    app.post["/boards"](post_board)
    app.post["/users"](post_users)
    app.post["/maybe"](post_maybe)
    app.post["/sessions"](post_session)
    app.post["/carried"](post_carried)
    app.put["/boards/{id}"](put_board, State(String("shelf")))
    app.post["/envelopes"](echo_envelope)
    app.post["/holders"](post_holder)
    var g = Group(check_key, State(String("k")))
    g.post["/guarded/{id}"](guarded_board)
    app.mount(g^)
    return app^


def json_headers(key: Bool = False) -> Headers:
    var h = Headers()
    try:
        h.add("Content-Type", "application/json")
        if key:
            h.add("X-Key", "k")
    except:
        pass
    return h^


def expect(r: Response, step: String, message: String) raises:
    """Muntin's 400 as the client sees it, carrying this `Rejection`."""
    assert_equal(r.status, 400, message)
    assert_equal(r.text(), "Bad Request", message)
    assert_equal(len(r.headers), 0, message)
    var got = r.rejection()
    assert_true(Bool(got), message)
    assert_equal(got.value().step, step, message)
    assert_equal(got.value().name, "", message)
    assert_equal(got.value().message, message)


def test_rejections_name_the_member_path() raises:
    var app = make_app()
    var c = TestClient(app)
    var ok = '{"title":"t","notes":[{"text":"a","tag":"x"}]}'
    assert_equal(c.post("/boards", ok, headers=json_headers()).text(), "t 1")
    # Not one JSON value: the parser's message, no path.
    expect(
        c.post("/boards", "{", headers=json_headers()),
        Rejection.JSON,
        "invalid JSON: expected member name",
    )
    # The top-level value of the wrong kind: no path.
    expect(
        c.post("/boards", "[]", headers=json_headers()),
        Rejection.FROM_JSON,
        "JSON value is not an object",
    )
    expect(
        c.post("/boards", '{"notes":[]}', headers=json_headers()),
        Rejection.FROM_JSON,
        "title: JSON member is missing",
    )
    expect(
        c.post("/boards", '{"title":null,"notes":[]}', headers=json_headers()),
        Rejection.FROM_JSON,
        "title: JSON value is not a string",
    )
    expect(
        c.post(
            "/boards",
            '{"title":"t","notes":[{"text":"a","tag":"x"},{"text":"b",'
            + '"tag":"y"},{"text":7,"tag":"z"}]}',
            headers=json_headers(),
        ),
        Rejection.FROM_JSON,
        "notes[2].text: JSON value is not a string",
    )
    expect(
        c.post(
            "/boards",
            '{"title":"t","notes":[{"text":"a"}]}',
            headers=json_headers(),
        ),
        Rejection.FROM_JSON,
        "notes[0].tag: JSON member is missing",
    )
    expect(
        c.post("/boards", '{"title":"t","notes":{}}', headers=json_headers()),
        Rejection.FROM_JSON,
        "notes: JSON value is not an array",
    )
    # An `Optional` member present with the wrong kind.
    expect(
        c.post(
            "/boards",
            '{"title":"t","notes":[],"pinned":{"text":"a","tag":[]}}',
            headers=json_headers(),
        ),
        Rejection.FROM_JSON,
        "pinned.tag: JSON value is not a string",
    )


def test_rejection_paths_through_lists_and_hand_written_fields() raises:
    var app = make_app()
    var c = TestClient(app)
    var user = (
        '{"id":1,"name":"n","admin":true,"score":0,"tags":[],'
        + '"home":{"city":"X","zip":1},"past":[],"grid":[[1],[2]]}'
    )
    assert_equal(
        c.post("/users", "[" + user + "]", headers=json_headers()).text(), "1"
    )
    # A top-level list: the path starts with the index.
    expect(
        c.post("/users", "[" + user + ",{}]", headers=json_headers()),
        Rejection.FROM_JSON,
        "[1].id: JSON member is missing",
    )
    expect(
        c.post(
            "/users",
            "[" + user.replace('"zip":1', '"zip":1.5') + "]",
            headers=json_headers(),
        ),
        Rejection.FROM_JSON,
        "[0].home.zip: JSON number is not an integer",
    )
    expect(
        c.post(
            "/users",
            "[" + user.replace("[[1],[2]]", '[[1],[2,"3"]]') + "]",
            headers=json_headers(),
        ),
        Rejection.FROM_JSON,
        "[0].grid[1][1]: JSON value is not a number",
    )
    expect(
        c.post("/users", "{}", headers=json_headers()),
        Rejection.FROM_JSON,
        "JSON value is not an array",
    )
    # A hand-written `FromJson` field's own error, under its member's path.
    expect(
        c.post(
            "/sessions",
            '{"user":"u","tokens":["a",{}],"main":"m","after":1}',
            headers=json_headers(),
        ),
        Rejection.FROM_JSON,
        "tokens[1]: JSON value is not a string",
    )


def test_top_level_optional_body() raises:
    var app = make_app()
    var c = TestClient(app)
    assert_equal(
        c.post("/maybe", "null", headers=json_headers()).text(), "none"
    )
    assert_equal(
        c.post(
            "/maybe", '{"text":"a","tag":"b"}', headers=json_headers()
        ).text(),
        "note a",
    )
    expect(
        c.post("/maybe", '{"text":"a"}', headers=json_headers()),
        Rejection.FROM_JSON,
        "tag: JSON member is missing",
    )


def test_carried_guarded_and_stateful_bodies() raises:
    var app = make_app()
    var c = TestClient(app)
    var ok = '{"title":"t","notes":[]}'
    var bad = '{"title":"t","notes":[{"text":"a"}]}'
    assert_equal(c.post("/carried", ok, headers=json_headers()).text(), "t 1")
    expect(
        c.post("/carried", bad, headers=json_headers()),
        Rejection.FROM_JSON,
        "notes[0].tag: JSON member is missing",
    )
    expect(
        c.post("/carried", "nope", headers=json_headers()),
        Rejection.JSON,
        "invalid JSON: bad literal",
    )
    # A guarded route: the guard answers first, then the deferred 400.
    assert_equal(
        c.post("/guarded/3", ok, headers=json_headers(True)).text(), "ada 3 t"
    )
    var refused = c.post("/guarded/3", bad, headers=json_headers())
    assert_equal(refused.status, 401)
    assert_false(Bool(refused.rejection()))
    expect(
        c.post("/guarded/3", bad, headers=json_headers(True)),
        Rejection.FROM_JSON,
        "notes[0].tag: JSON member is missing",
    )
    # A stateful handler with a route value, then the derived body.
    assert_equal(
        c.put("/boards/4", ok, headers=json_headers()).text(), "4 t shelf"
    )
    expect(
        c.put("/boards/4", bad, headers=json_headers()),
        Rejection.FROM_JSON,
        "notes[0].tag: JSON member is missing",
    )


def test_raw_from_body_raises_the_same_text() raises:
    var raised = String()
    try:
        _ = Json[Board].from_body('{"title":"t","notes":[{"text":"a"}]}')
    except e:
        raised = String(e)
    assert_equal(raised, "notes[0].tag: JSON member is missing")
    try:
        _ = Json[Board].from_body("{")
    except e:
        raised = String(e)
    assert_equal(raised, "invalid JSON: expected member name")


def test_top_level_optional_and_list_results() raises:
    assert_equal(_text(Json(Optional[Note]()).to_response()), "null")
    assert_equal(
        _text(Json(Optional(Note(1, "a", "b", "c"))).to_response()),
        '{"id":1,"owner":"a","text":"b","tag":"c"}',
    )
    assert_equal(_text(Json(List[Note]()).to_response()), "[]")
    # A top-level `List` of a scalar, both ways.
    var ints: List[Int] = [1, 2]
    assert_equal(_text(Json(ints^).to_response()), "[1,2]")
    assert_equal(Json[List[Int]].from_body("[3,4]").value[1], 4)
    # A top-level `List` of a hand-written `ToJson` type.
    var tokens = List[Token]()
    tokens.append(Token("a"))
    assert_equal(_text(Json(tokens^).to_response()), '["<a>"]')


def test_a_failed_write_is_the_fixed_500() raises:
    var u = User(
        1,
        "n",
        True,
        Float64.MAX * 2,
        [],
        None,
        Address("X", 1),
        [],
        [],
        None,
    )
    var r = Json(u^).to_response()
    assert_equal(r.status, 500)
    assert_equal(_text(r), "Internal Server Error")
    assert_equal(r.failure().value().message, "JSON writer: non-finite number")


# Derived values inside hand-written codecs (M3-087): a hand-written
# `write_json` writes a `JsonFields` struct, an `Optional` or a `List` of
# one through `out.field` and `out.value`, the text `Json[T]` writes; a
# hand-written `from_json` reads any derived kind through
# `JsonValue.read[T]()` and `read[T](name)`, the derived member path first;
# a type that is both `JsonFields` and `ToJson` keeps its own writer.


@fieldwise_init
struct Place(Copyable, JsonFields):
    var city: String
    var zip: Optional[Int]
    var tags: List[String]


@fieldwise_init
struct Badge(Copyable, JsonFields, ToJson):
    """Both: its own writer takes over inside a hand-written one too."""

    var n: Int

    def write_json(self, mut out: JsonWriter) raises:
        out.string("badge " + String(self.n))


@fieldwise_init
struct Envelope(Copyable, FromJson, ToJson):
    """One special member (`version`, checked and renamed), the rest
    derived: what a type needed every nested DTO written by hand for."""

    var version: Int
    var place: Place
    var spare: Optional[Place]
    var trail: List[Place]
    var badge: Badge

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
            Badge(value.read[Int]("badge")),
        )

    def write_json(self, mut out: JsonWriter) raises:
        out.begin_object()
        out.field("v", self.version)
        out.field("place", self.place)
        out.field("spare", self.spare)
        out.field("trail", self.trail)
        out.field("badge", self.badge)
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


def echo_envelope(body: Json[Envelope]) -> Json[Envelope]:
    return Json(body.value.copy())


def post_holder(body: Json[Holder]) -> String:
    return body.value.env.place.city


comptime PLACE = '{"city":"X","zip":1,"tags":["a"]}'
comptime OTHER_PLACE = '{"city":"Y","zip":null,"tags":[]}'
comptime ENVELOPE = (
    '{"v":2,"place":'
    + PLACE
    + ',"trail":['
    + PLACE
    + ","
    + OTHER_PLACE
    + '],"badge":3}'
)


def test_hand_written_writer_writes_derived_values() raises:
    var app = make_app()
    var c = TestClient(app)
    var r = c.post("/envelopes", ENVELOPE, headers=json_headers())
    assert_equal(r.status, 200)
    assert_equal(
        r.text(),
        '{"v":2,"place":'
        + PLACE
        + ',"spare":null,"trail":['
        + PLACE
        + ","
        + OTHER_PLACE
        + '],"badge":"badge 3","again":['
        + PLACE
        + ",null,["
        + PLACE
        + ","
        + OTHER_PLACE
        + "]]}",
    )
    # A full `Optional` both ways, as the derived text.
    var full = String(ENVELOPE).replace(
        '"trail":', '"spare":' + OTHER_PLACE + ',"trail":'
    )
    r = c.post("/envelopes", full, headers=json_headers())
    assert_equal(r.status, 200)
    var both = PLACE + "," + OTHER_PLACE
    assert_equal(
        r.text(),
        '{"v":2,"place":'
        + PLACE
        + ',"spare":'
        + OTHER_PLACE
        + ',"trail":['
        + both
        + '],"badge":"badge 3","again":['
        + both
        + ",["
        + both
        + "]]}",
    )
    # The same text `Json[T]` writes for the member's type.
    assert_equal(
        _text(Json(Place("X", Optional[Int](1), ["a"])).to_response()), PLACE
    )


struct Badges(ToJson):
    var many: List[Badge]
    var maybe: Optional[Badge]

    def __init__(out self):
        self.many = [Badge(1), Badge(2)]
        self.maybe = Optional(Badge(3))

    def write_json(self, mut out: JsonWriter) raises:
        out.begin_object()
        out.field("many", self.many)
        out.field("maybe", self.maybe)
        out.end_object()


def test_a_to_json_type_keeps_its_writer_inside_a_hand_written_one() raises:
    assert_equal(
        _text(Json(Badges()).to_response()),
        '{"many":["badge 1","badge 2"],"maybe":"badge 3"}',
    )


def test_hand_written_reader_keeps_the_member_path() raises:
    var app = make_app()
    var c = TestClient(app)
    expect(
        c.post(
            "/envelopes",
            String(ENVELOPE).replace('"city":"X"', '"city":1'),
            headers=json_headers(),
        ),
        Rejection.FROM_JSON,
        "place.city: JSON value is not a string",
    )
    expect(
        c.post(
            "/envelopes", '{"v":2,"trail":[],"badge":1}', headers=json_headers()
        ),
        Rejection.FROM_JSON,
        "place: JSON member is missing",
    )
    expect(
        c.post(
            "/envelopes",
            String(ENVELOPE).replace('"tags":[]', '"tags":[true]'),
            headers=json_headers(),
        ),
        Rejection.FROM_JSON,
        "trail[1].tags[0]: JSON value is not a string",
    )
    expect(
        c.post(
            "/envelopes",
            String(ENVELOPE).replace('"badge":3', '"badge":"3"'),
            headers=json_headers(),
        ),
        Rejection.FROM_JSON,
        "badge: JSON value is not a number",
    )
    expect(
        c.post(
            "/envelopes",
            String(ENVELOPE).replace('"v":2', '"v":1'),
            headers=json_headers(),
        ),
        Rejection.FROM_JSON,
        "unsupported version",
    )
    # Under a derived parent, the parent's path, then the hand-written
    # reader's message, which starts with its own path.
    assert_equal(
        c.post(
            "/holders",
            '{"label":"l","env":' + ENVELOPE + "}",
            headers=json_headers(),
        ).text(),
        "X",
    )
    expect(
        c.post(
            "/holders",
            '{"label":"l","env":'
            + String(ENVELOPE).replace('"city":"X"', '"city":1')
            + "}",
            headers=json_headers(),
        ),
        Rejection.FROM_JSON,
        "env: place.city: JSON value is not a string",
    )
    # `read[T]()`: the path below the value itself.
    var raised = String()
    try:
        _ = _parse('{"city":"X","tags":[1]}').read[Place]()
    except e:
        raised = String(e)
    assert_equal(raised, "tags[0]: JSON value is not a string")


struct Inner(FromJson, Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        return Self(value.read[Int]("n"))


struct Keep(FromJson, Movable):
    """The parsed value itself, for `read` outside a body."""

    var value: JsonValue

    def __init__(out self, value: JsonValue):
        self.value = value.copy()

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        return Self(value)


def _parse(text: String) raises -> JsonValue:
    var k = Json[Keep].from_body(text).take()
    return k.value.copy()


def _read_raised[T: Movable & Deinitable](text: String, name: String) -> String:
    try:
        _ = _parse(text).read[T](name)
        return "ok"
    except e:
        return String(e)


def test_read_kinds_and_paths() raises:
    # `null` and absence are both an empty `Optional`, as a derived field.
    var v = _parse('{"p":null,"l":[{"n":1},{"n":2}]}')
    assert_false(Bool(v.read[Optional[Place]]("p")))
    assert_false(Bool(v.read[Optional[Place]]("q")))
    assert_false(Bool(_parse("null").read[Optional[Place]]()))
    var full = _parse('{"p":' + OTHER_PLACE + "}").read[Optional[Place]]("p")
    assert_equal(full.value().city, "Y")
    assert_false(Bool(full.value().zip))
    # Every scalar kind, and a `List` and `Optional` of one.
    var s = _parse('{"f":1.5,"b":true,"s":"x","l":[1,2],"o":"y","n":null}')
    assert_equal(s.read[Float64]("f"), 1.5)
    assert_true(s.read[Bool]("b"))
    assert_equal(s.read[String]("s"), "x")
    assert_equal(s.read[List[Int]]("l")[1], 2)
    assert_equal(s.read[Optional[String]]("o").value(), "y")
    assert_false(Bool(s.read[Optional[String]]("n")))
    assert_equal(
        _read_raised[List[Int]]('{"l":[1,"2"]}', "l"),
        "l[1]: JSON value is not a number",
    )
    # A `List` of a hand-written type, and its own `read` inside: each
    # hand-written boundary adds its own `: `.
    assert_equal(len(v.read[List[Inner]]("l")), 2)
    assert_equal(
        _read_raised[List[Inner]]('{"l":[{"n":1},{}]}', "l"),
        "l[1]: n: JSON member is missing",
    )
    assert_equal(
        _read_raised[Inner]('{"i":{"n":"x"}}', "i"),
        "i: n: JSON value is not a number",
    )
    # Not an object: the parse step's message, without a path.
    assert_equal(_read_raised[Int]("[1]", "n"), "JSON value is not an object")


struct Purse(FromJson, Movable):
    """A hand-written reader reading a derived `Wallet`, then a member of
    its own."""

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
        assert_equal(p.value.wallet.token.text, "t")
        return "ok"
    except e:
        return String(e)


def test_ownership_inside_and_after_a_read() raises:
    var long = String("x") * 64  # heap-allocated
    var w = '{"owner":"' + long + '","token":"t","count":1}'
    _reset()
    assert_equal(_purse('{"wallet":' + w + ',"after":1}'), "ok")
    assert_equal(_count(MADE), 1)
    assert_equal(_count(DROPPED), 1)
    # A failure inside the read: the built fields dropped once.
    _reset()
    assert_equal(
        _purse('{"wallet":' + w.replace('"count":1', '"count":"1"') + "}"),
        "wallet.count: JSON value is not a number",
    )
    assert_equal(_count(MADE), 1)
    assert_equal(_count(DROPPED), 1)
    # A failure after it: the read wallet dropped once, by the application.
    _reset()
    assert_equal(
        _purse('{"wallet":' + w + "}"), 'JSON member "after" is missing'
    )
    assert_equal(_count(MADE), 1)
    assert_equal(_count(DROPPED), 1)
    # A `List` read part-way: the elements built before the failure dropped
    # once.
    _reset()
    assert_equal(
        _read_raised[List[Token]]('{"l":["a","b",1]}', "l"),
        "l[2]: JSON value is not a string",
    )
    assert_equal(_count(MADE), 2)
    assert_equal(_count(DROPPED), 2)


@fieldwise_init
struct Ticket(JsonFields):
    """Move-only, derived, holding a counted token."""

    var token: Token


struct Desk(ToJson):
    """Move-only derived values written through the hand-written writer's
    `JsonFields` overloads, alone, in an `Optional` and in a `List`."""

    var one: Ticket
    var maybe: Optional[Ticket]
    var many: List[Ticket]

    def __init__(out self):
        self.one = Ticket(Token("a"))
        self.maybe = Optional(Ticket(Token("b")))
        self.many = List[Ticket]()
        self.many.append(Ticket(Token("c")))
        self.many.append(Ticket(Token("d")))

    def write_json(self, mut out: JsonWriter) raises:
        out.begin_object()
        out.field("one", self.one)
        out.field("maybe", self.maybe)
        out.field("many", self.many)
        out.name("again")
        out.begin_array()
        out.value(self.one)
        out.value(self.maybe)
        out.value(self.many)
        out.end_array()
        out.end_object()


def test_move_only_derived_values_written_by_hand() raises:
    _reset()
    var desk = Desk()
    assert_equal(_count(MADE), 4)
    var r = Json(desk^).to_response()
    var one = '{"token":"<a>"}'
    var maybe = '{"token":"<b>"}'
    var many = '[{"token":"<c>"},{"token":"<d>"}]'
    assert_equal(
        _text(r),
        '{"one":'
        + one
        + ',"maybe":'
        + maybe
        + ',"many":'
        + many
        + ',"again":['
        + one
        + ","
        + maybe
        + ","
        + many
        + "]}",
    )
    # Written by reference: nothing copied, each token dropped once.
    assert_equal(_count(MADE), 4)
    assert_equal(_count(DROPPED), 4)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
