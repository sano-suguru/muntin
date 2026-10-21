# Guarded groups (M3-081, decided in M3-080): the notes application (#167)
# with its authentication written once, as a `Group`'s guard, and a second
# group whose routes reach each of the eight guarded adapters with and
# without the context. Counters show each context value, guard state and
# handler state dropped once; `SANITIZE=address ./scripts/test.sh` runs the
# same requests under AddressSanitizer.

from std.memory import ArcPointer
from std.testing import assert_equal, assert_false, assert_true, TestSuite

from muntin import (
    App,
    WithHeaders,
    FromJson,
    Group,
    Headers,
    Json,
    JsonValue,
    JsonWriter,
    Next,
    Request,
    Response,
    State,
    ToErrorResponse,
    RouteValues,
    ToJson,
)
from muntin.testing import TestClient


# Counters the tests read: live context values, guard calls, live services.
struct Counts(Movable):
    var users_live: ArcPointer[Int]
    var users_made: ArcPointer[Int]
    var guard_calls: ArcPointer[Int]
    var services_live: ArcPointer[Int]
    var handler_calls: ArcPointer[Int]
    var configs_live: ArcPointer[Int]

    def __init__(out self):
        self.users_live = ArcPointer(0)
        self.users_made = ArcPointer(0)
        self.guard_calls = ArcPointer(0)
        self.services_live = ArcPointer(0)
        self.handler_calls = ArcPointer(0)
        self.configs_live = ArcPointer(0)

    def copy(self) -> Self:
        var c = Self()
        c.users_live = self.users_live
        c.users_made = self.users_made
        c.guard_calls = self.guard_calls
        c.services_live = self.services_live
        c.handler_calls = self.handler_calls
        c.configs_live = self.configs_live
        return c^


struct Note(Copyable, Movable):
    var id: Int
    var owner: String
    var text: String

    def __init__(out self, id: Int, owner: String, text: String):
        self.id = id
        self.owner = owner
        self.text = text


struct Service(Movable):
    """Built once at start-up: the token table and the notes."""

    var tokens: Dict[String, String]
    var notes: ArcPointer[List[Note]]
    var max_text: Int
    var counts: Counts

    def __init__(
        out self,
        var tokens: Dict[String, String],
        max_text: Int,
        counts: Counts,
    ):
        self.tokens = tokens^
        self.notes = ArcPointer(List[Note]())
        self.max_text = max_text
        self.counts = counts.copy()
        self.counts.services_live[] += 1

    def __deinit__(deinit self):
        self.counts.services_live[] -= 1


struct User(Movable):
    """The authenticated user: the group's context type."""

    var name: String
    var counts: Counts

    def __init__(out self, name: String, counts: Counts):
        self.name = name
        self.counts = counts.copy()
        self.counts.users_live[] += 1
        self.counts.users_made[] += 1

    def __init__(out self, *, deinit move: Self):
        self.name = move.name^
        self.counts = move.counts^

    def __deinit__(deinit self):
        self.counts.users_live[] -= 1


@fieldwise_init
struct ApiError(Movable, ToErrorResponse):
    var status: Int
    var message: String

    def to_error_response(deinit self) -> Response:
        var response = Response.text(self.message, status=self.status)
        if self.status == 401:
            try:
                response.headers.add("WWW-Authenticate", "Bearer")
            except:
                pass
        return response^


@fieldwise_init
struct NoteJson(ToJson):
    var note: Note

    def write_json(self, mut out: JsonWriter) raises:
        out.begin_object()
        out.field("id", self.note.id)
        out.field("owner", self.note.owner)
        out.field("text", self.note.text)
        out.end_object()


@fieldwise_init
struct NoteList(ToJson):
    var notes: List[Note]

    def write_json(self, mut out: JsonWriter) raises:
        out.begin_array()
        for note in self.notes:
            NoteJson(note.copy()).write_json(out)
        out.end_array()


@fieldwise_init
struct NewNote(FromJson):
    var text: String

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        return Self(value["text"].string())


# The one authentication: start-up values through the guard's state.
def authenticate(svc: State[Service], headers: Headers) raises ApiError -> User:
    svc[].counts.guard_calls[] += 1
    var field = headers.get("authorization").or_else("")
    if field.lower().startswith("bearer "):
        var token = String(field[byte=7:])
        var name = svc[].tokens.get(token)
        if name:
            return User(name.value(), svc[].counts)
    raise ApiError(401, "Unauthorized")


# Handlers: none calls `authenticate`.
def list_notes(svc: State[Service], user: User) -> Json[NoteList]:
    svc[].counts.handler_calls[] += 1
    var mine = List[Note]()
    for note in svc[].notes[]:
        if note.owner == user.name:
            mine.append(note.copy())
    return Json(NoteList(mine^))


def get_note(
    svc: State[Service], user: User, id: Int
) raises ApiError -> Json[NoteJson]:
    svc[].counts.handler_calls[] += 1
    for note in svc[].notes[]:
        if note.id == id and note.owner == user.name:
            return Json(NoteJson(note.copy()))
    raise ApiError(404, String("no note ", id))


def create_note(
    svc: State[Service], user: User, input: Json[NewNote]
) raises ApiError -> Json[NoteJson]:
    svc[].counts.handler_calls[] += 1
    ref text = input.value.text
    if text.byte_length() > svc[].max_text:
        raise ApiError(422, "text too long")
    var note = Note(len(svc[].notes[]) + 1, user.name, text)
    svc[].notes[].append(note.copy())
    return Json(NoteJson(note^), status=201)


# The fourth protected route, added without an authentication line.
def delete_note(
    svc: State[Service], user: User, id: Int
) raises ApiError -> String:
    svc[].counts.handler_calls[] += 1
    for i in range(len(svc[].notes[])):
        if svc[].notes[][i].id == id and svc[].notes[][i].owner == user.name:
            _ = svc[].notes[].pop(i)
            return "deleted"
    raise ApiError(404, String("no note ", id))


# A protected route whose handler does not need the user.
def count(svc: State[Service]) -> String:
    svc[].counts.handler_calls[] += 1
    return String(len(svc[].notes[]))


def health() -> String:
    return "ok"


# Raw handlers in a group, with and without the context.
def whoami(user: User, request: Request) -> Response:
    return Response.text(
        user.name
        + " "
        + request.method
        + " "
        + request.path
        + "?"
        + request.query
        + " "
        + request.headers.get("X-Probe").or_else("-")
    )


def whoami_state(svc: State[Service], user: User, request: Request) -> Response:
    return Response.text(
        user.name + " " + request.path + " " + String(len(request.body))
    )


def raw_plain(request: Request) -> Response:
    return Response.text("raw " + request.path)


def anyone(svc: State[Service], headers: Headers) -> User:
    """A guard that admits every request."""
    svc[].counts.guard_calls[] += 1
    return User(headers.get("X-Name").or_else("anon"), svc[].counts)


def tag(var request: Request, var next: Next) raises -> Response:
    var response = next^.run(request^)
    response.headers.add("X-Tag", "1")
    return response^


def make_app(counts: Counts) -> App:
    var tokens = Dict[String, String]()
    tokens["t-ada"] = "ada"
    tokens["t-bob"] = "bob"
    var svc = State(Service(tokens^, 20, counts))
    var app = App()
    app.use(tag)
    app.get["/health"](health)
    var notes = Group(authenticate, svc)
    notes.get["/notes"](list_notes, svc)
    notes.get["/notes/{id}"](get_note, svc)
    notes.post["/notes"](create_note, svc)
    notes.delete["/notes/{id}"](delete_note, svc)
    notes.get["/count"](count, svc)
    notes.get["/whoami"](whoami)
    notes.post["/whoami-state"](whoami_state, svc)
    notes.get["/raw"](raw_plain)
    app.mount(notes^)
    var open = Group(anyone, svc)
    open.get["/open"](whoami)
    open.get["/open/{id}"](get_note, svc)
    app.mount(open^)
    return app^


def _auth(token: String) raises -> Headers:
    var h = Headers()
    h.add("Authorization", "Bearer " + token)
    return h^


def _json(token: String) raises -> Headers:
    var h = _auth(token)
    h.add("Content-Type", "application/json")
    return h^


def _no_token_json() raises -> Headers:
    var h = Headers()
    h.add("Content-Type", "application/json")
    return h^


def test_protected_routes_receive_the_user() raises:
    var counts = Counts()
    var app = make_app(counts)
    var client = TestClient(app)
    var r = client.post("/notes", '{"text":"hi"}', headers=_json("t-ada"))
    assert_equal(r.status, 201)
    assert_equal(r.text(), '{"id":1,"owner":"ada","text":"hi"}')
    r = client.get("/notes", headers=_auth("t-ada"))
    assert_equal(r.status, 200)
    assert_equal(r.text(), '[{"id":1,"owner":"ada","text":"hi"}]')
    r = client.get("/notes", headers=_auth("t-bob"))
    assert_equal(r.text(), "[]")
    r = client.get("/notes/1", headers=_auth("t-ada"))
    assert_equal(r.status, 200)
    r = client.get("/notes/1", headers=_auth("t-bob"))
    assert_equal(r.status, 404)
    r = client.delete("/notes/1", headers=_auth("t-ada"))
    assert_equal(r.text(), "deleted")
    assert_equal(r.headers.get("X-Tag").or_else(""), "1")
    assert_equal(counts.users_live[], 0)


def test_no_token_is_401_on_every_protected_route() raises:
    var counts = Counts()
    var app = make_app(counts)
    var client = TestClient(app)
    for path in ["/notes", "/notes/1", "/count"]:
        var r = client.get(path)
        assert_equal(r.status, 401)
        assert_equal(r.headers.get("WWW-Authenticate").or_else(""), "Bearer")
        assert_equal(r.headers.get("X-Tag").or_else(""), "1")
    assert_equal(client.delete("/notes/1").status, 401)
    assert_equal(client.get("/notes", headers=_auth("t-eve")).status, 401)
    assert_equal(client.head("/notes").status, 401)
    assert_equal(counts.handler_calls[], 0)
    assert_equal(counts.users_made[], 0)


def test_401_comes_before_conversion_400() raises:
    var counts = Counts()
    var app = make_app(counts)
    var client = TestClient(app)
    # Malformed body, no token: 401, not 400.
    assert_equal(
        client.post("/notes", "{not json", headers=_no_token_json()).status, 401
    )
    # Wrong media type, no token: 401, not 415.
    assert_equal(client.post("/notes", '{"text":"x"}').status, 401)
    # Bad route value (not an Int), no token: 401, not 400.
    assert_equal(client.get("/notes/abc").status, 401)
    # Bad escape in a route value, no token: 401 (a deferred decode 400).
    assert_equal(client.get("/notes/%zz").status, 401)
    # The same with a token: the conversions' own answers.
    assert_equal(
        client.post("/notes", "{not json", headers=_json("t-ada")).status, 400
    )
    assert_equal(
        client.post("/notes", '{"text":"x"}', headers=_auth("t-ada")).status,
        415,
    )
    assert_equal(client.get("/notes/abc", headers=_auth("t-ada")).status, 400)
    assert_equal(client.get("/notes/%zz", headers=_auth("t-ada")).status, 400)
    assert_equal(counts.handler_calls[], 0)
    assert_equal(counts.users_live[], 0)


def test_unprotected_and_unmatched_are_unchanged() raises:
    var counts = Counts()
    var app = make_app(counts)
    var client = TestClient(app)
    assert_equal(client.get("/health").text(), "ok")
    assert_equal(client.get("/missing").status, 404)
    var r = client.put("/notes", "")
    assert_equal(r.status, 405)
    assert_equal(r.headers.get("Allow").or_else(""), "GET, HEAD, POST")
    assert_equal(counts.guard_calls[], 0)


def test_one_user_per_request_dropped_once() raises:
    var counts = Counts()
    var app = make_app(counts)
    var client = TestClient(app)
    for _ in range(5):
        _ = client.get("/notes", headers=_auth("t-ada"))
        _ = client.get("/count", headers=_auth("t-ada"))
        _ = client.get("/notes/abc", headers=_auth("t-ada"))
    assert_equal(counts.guard_calls[], 15)
    assert_equal(counts.users_made[], 15)
    assert_equal(counts.users_live[], 0)


def test_app_moved_between_requests() raises:
    var counts = Counts()
    var app = make_app(counts)
    assert_equal(
        TestClient(app).get("/count", headers=_auth("t-ada")).text(), "0"
    )
    var moved = app^
    assert_equal(
        TestClient(moved).get("/count", headers=_auth("t-bob")).text(), "0"
    )
    assert_equal(counts.users_live[], 0)


def test_service_dropped_once_with_the_app() raises:
    var counts = Counts()
    var app = make_app(counts)
    _ = TestClient(app).get("/notes", headers=_auth("t-ada"))
    assert_equal(counts.services_live[], 1)
    _ = app^
    assert_equal(counts.services_live[], 0)
    assert_equal(counts.users_live[], 0)


def test_raw_handlers_in_a_group() raises:
    var counts = Counts()
    var app = make_app(counts)
    var client = TestClient(app)
    var h = _auth("t-ada")
    h.add("X-Probe", "p")
    var r = client.get("/whoami?q=1", headers=h^)
    assert_equal(r.status, 200)
    assert_equal(r.text(), "ada GET /whoami?q=1 p")
    assert_equal(client.get("/whoami?q").status, 401)
    r = client.post("/whoami-state", "abc", headers=_auth("t-bob"))
    assert_equal(r.text(), "bob /whoami-state 3")
    assert_equal(client.post("/whoami-state", "abc").status, 401)
    assert_equal(client.get("/raw", headers=_auth("t-ada")).text(), "raw /raw")
    assert_equal(client.get("/raw").status, 401)
    assert_equal(counts.users_live[], 0)


def test_a_guard_that_admits_everyone() raises:
    var counts = Counts()
    var app = make_app(counts)
    var client = TestClient(app)
    var h = Headers()
    h.add("authorization", "x")
    var r = client.get("/open?q", headers=h^)
    assert_equal(r.status, 200)
    assert_equal(r.text(), "anon GET /open?q -")
    var n = Headers()
    n.add("X-Name", "eve")
    n.add("X-Probe", "z")
    assert_equal(
        client.get("/open?a=1&b", headers=n^).text(), "eve GET /open?a=1&b z"
    )
    assert_equal(client.get("/open/abc").status, 400)
    assert_equal(client.get("/open/%zz").status, 400)
    assert_equal(client.get("/open/7").status, 404)
    assert_equal(counts.users_live[], 0)


# A second group: the guard's state is not the handlers' state, and its
# routes go through the adapters the notes group leaves out (no slot, and
# three slots with and without `State`).
struct AuthConfig(Movable):
    var key: String
    var counts: Counts

    def __init__(out self, key: String, counts: Counts):
        self.key = key
        self.counts = counts.copy()
        self.counts.configs_live[] += 1

    def __deinit__(deinit self):
        self.counts.configs_live[] -= 1


def check_key(cfg: State[AuthConfig], headers: Headers) raises ApiError -> User:
    """Makes the user before it refuses a revoked key."""
    cfg[].counts.guard_calls[] += 1
    if headers.get("X-Key").or_else("") != cfg[].key:
        raise ApiError(401, "Unauthorized")
    var user = User("ada", cfg[].counts)
    if headers.get("X-Revoked"):
        raise ApiError(403, "revoked")
    return user^


def ping() -> String:
    return "pong"


def echo3(user: User, id: Int, input: Json[NewNote]) -> String:
    return user.name + " " + String(id) + " " + input.value.text


def update(
    svc: State[Service], user: User, id: Int, input: WithHeaders[Json[NewNote]]
) -> String:
    return (
        user.name
        + " "
        + String(id)
        + " "
        + input.body.value.text
        + " "
        + input.headers.get("X-Probe").or_else("-")
        + " "
        + String(svc[].max_text)
    )


def plain_id(id: Int) -> String:
    return String(id)


def me(user: User) -> String:
    return user.name


def id_headers(id: Int, headers: Headers) -> String:
    return String(id) + " " + _fields(headers)


def state_id(svc: State[Service], id: Int) -> String:
    return String(id) + " " + String(svc[].max_text)


def state_me(svc: State[Service], user: User) -> String:
    return user.name + " " + String(svc[].max_text)


def state_user_id(svc: State[Service], user: User, id: Int) -> String:
    return user.name + " " + String(id) + " " + String(svc[].max_text)


def state_no_user(svc: State[Service], id: Int, input: Json[NewNote]) -> String:
    return String(id) + " " + input.value.text + " " + String(svc[].max_text)


# Slot layouts the guard must cut correctly: three slots without the user,
# and route-value records several values wide.
def ids_headers(a: Int, b: Int, headers: Headers) -> String:
    return _ids(a, b) + " " + _fields(headers)


def ids_json(a: Int, b: Int, input: Json[NewNote]) -> String:
    return _ids(a, b) + " " + input.value.text


def state_ids_headers(
    svc: State[Service], a: Int, b: Int, headers: Headers
) -> String:
    return String(svc[].max_text) + " " + _ids(a, b) + " " + _fields(headers)


@fieldwise_init
struct At(RouteValues):
    var org: Int
    var project: String
    var task: Int


@fieldwise_init
struct Find(RouteValues):
    var org: Int
    var q: String
    var limit: Optional[Int]


def _ids(a: Int, b: Int) -> String:
    return String(a) + "," + String(b)


def _at(at: At) -> String:
    return String(at.org) + "/" + at.project + "/" + String(at.task)


def _fields(headers: Headers) -> String:
    """Every field the handler receives, in order."""
    var out = String(len(headers))
    for i in range(len(headers)):
        out += " " + headers.name(i) + "=" + headers.value(i)
    return out


def user_at_headers(user: User, at: At, headers: Headers) -> String:
    return user.name + " " + _at(at) + " " + _fields(headers)


def at_json(at: At, input: Json[NewNote]) -> String:
    return _at(at) + " " + input.value.text


def state_user_at_carried(
    svc: State[Service], user: User, at: At, input: WithHeaders[Json[NewNote]]
) -> String:
    return (
        user.name
        + " "
        + _at(at)
        + " "
        + input.body.value.text
        + " "
        + _fields(input.headers)
    )


def user_find(user: User, find: Find) -> String:
    var limit = String(find.limit.value()) if find.limit else "-"
    return user.name + " " + String(find.org) + " " + find.q + " " + limit


def make_keyed(counts: Counts) -> App:
    var cfg = State(AuthConfig("k1", counts))
    var svc = State(Service(Dict[String, String](), 20, counts))
    var app = App()
    var keyed = Group(check_key, cfg)
    keyed.get["/k/ping"](ping)
    keyed.post["/k/echo/{id}"](echo3)
    keyed.put["/k/notes/{id}"](update, svc)
    keyed.get["/k/id/{id}"](plain_id)
    keyed.post["/k/s/{id}"](state_no_user, svc)
    keyed.get["/k/ih/{a}?{b}"](ids_headers)
    keyed.post["/k/ij/{a}/{b}"](ids_json)
    keyed.get["/k/sih/{a}/{b}"](state_ids_headers, svc)
    keyed.get["/k/r/{org}/{project}/{task}"](user_at_headers)
    keyed.post["/k/r/{org}/{project}/{task}"](at_json)
    keyed.put["/k/r/{org}/{project}/{task}"](state_user_at_carried, svc)
    keyed.get["/k/f/{org}?{q}&{limit}"](user_find)
    keyed.get["/k/me"](me)
    keyed.get["/k/idh/{id}"](id_headers)
    keyed.get["/k/sid/{id}"](state_id, svc)
    keyed.get["/k/sme"](state_me, svc)
    keyed.get["/k/su/{id}"](state_user_id, svc)
    keyed.get["/k/count"](count, svc)
    app.mount(keyed^)
    return app^


def _key(json: Bool = False) raises -> Headers:
    var h = Headers()
    h.add("X-Key", "k1")
    if json:
        h.add("Content-Type", "application/json")
    return h^


def test_other_adapters_and_a_separate_guard_state() raises:
    var counts = Counts()
    var app = make_keyed(counts)
    var client = TestClient(app)
    assert_equal(client.get("/k/ping", headers=_key()).text(), "pong")
    assert_equal(client.get("/k/ping").status, 401)
    var r = client.post("/k/echo/5", '{"text":"hi"}', headers=_key(True))
    assert_equal(r.text(), "ada 5 hi")
    assert_equal(
        client.post("/k/echo/5", "{bad", headers=_no_token_json()).status, 401
    )
    assert_equal(
        client.post("/k/echo/abc", '{"text":"hi"}', headers=_key(True)).status,
        400,
    )
    assert_equal(
        client.post("/k/echo/5", "{bad", headers=_key(True)).status, 400
    )
    var h = _key(True)
    h.add("X-Probe", "p")
    r = client.put("/k/notes/3", '{"text":"hi"}', headers=h^)
    assert_equal(r.text(), "ada 3 hi p 20")
    assert_equal(
        client.put(
            "/k/notes/3", '{"text":"hi"}', headers=_no_token_json()
        ).status,
        401,
    )
    assert_equal(
        client.put("/k/notes/3", '{"text":"hi"}', headers=_key()).status, 415
    )
    assert_equal(
        client.put("/k/notes/x", '{"text":"hi"}', headers=_key(True)).status,
        400,
    )
    # Conversions of a handler that takes no user.
    assert_equal(client.get("/k/id/abc").status, 401)
    assert_equal(client.get("/k/id/abc", headers=_key()).status, 400)
    assert_equal(client.get("/k/id/4", headers=_key()).text(), "4")
    assert_equal(
        client.post("/k/s/2", '{"text":"yo"}', headers=_key(True)).text(),
        "2 yo 20",
    )
    assert_equal(
        client.post("/k/s/2", "{bad", headers=_no_token_json()).status, 401
    )
    assert_equal(client.post("/k/s/2", "{bad", headers=_key(True)).status, 400)
    assert_equal(counts.users_live[], 0)


def _status(r: Response) -> String:
    return String(r.status)


def test_each_guarded_adapter_with_and_without_the_context() raises:
    """One route per guarded adapter and context position, each answered
    with a key, refused without one, and, where it converts a value, 400
    with a key and a bad value."""
    var counts = Counts()
    var app = make_keyed(counts)
    var client = TestClient(app)
    # (route, its answer with a key, a bad value's route or "", adapter)
    var rows: List[List[String]] = [
        ["/k/ping", "pong", "", "0, no slot"],
        ["/k/id/4", "4", "/k/id/x", "1, without"],
        ["/k/me", "ada", "", "1, the context alone"],
        ["/k/idh/4", "4 1 X-Key=k1", "/k/idh/x", "2, without"],
        ["/k/f/1?q=a", "ada 1 a -", "/k/f/x?q=a", "2, with"],
        ["/k/sih/5/6", "20 5,6 1 X-Key=k1", "/k/sih/5/x", "3, without"],
        ["/k/r/7/web/9", "ada 7/web/9 1 X-Key=k1", "/k/r/x/web/9", "3, with"],
        ["/k/count", "0", "", "state 0, no slot"],
        ["/k/sid/3", "3 20", "/k/sid/x", "state 1, without"],
        ["/k/sme", "ada 20", "", "state 1, the context alone"],
        ["/k/su/3", "ada 3 20", "/k/su/x", "state 2, with"],
    ]
    for row in rows:
        var r = client.get(row[0], headers=_key())
        assert_equal(r.text(), row[1], row[3])
        assert_equal(client.get(row[0]).status, 401, row[3])
        if row[2] != "":
            assert_equal(client.get(row[2]).status, 401, row[3])
            assert_equal(client.get(row[2], headers=_key()).status, 400, row[3])
    # The body-taking ones: state 2 and 3, with and without, and 3 with.
    var posts: List[List[String]] = [
        ["/k/s/2", "post", "2 yo 20", "state 2, without"],
        ["/k/notes/3", "put", "ada 3 yo - 20", "state 3, with"],
        ["/k/echo/5", "post", "ada 5 yo", "3, with a body"],
        ["/k/ij/3/4", "post", "3,4 yo", "3, without a body"],
    ]
    for row in posts:
        var r: Response
        if row[1] == "put":
            r = client.put(row[0], '{"text":"yo"}', headers=_key(True))
        else:
            r = client.post(row[0], '{"text":"yo"}', headers=_key(True))
        assert_equal(r.text(), row[2], row[3])
        var refused: Response
        var bad: Response
        if row[1] == "put":
            refused = client.put(row[0], "{bad", headers=_no_token_json())
            bad = client.put(row[0], "{bad", headers=_key(True))
        else:
            refused = client.post(row[0], "{bad", headers=_no_token_json())
            bad = client.post(row[0], "{bad", headers=_key(True))
        assert_equal(refused.status, 401, row[3])
        assert_equal(bad.status, 400, row[3])
    assert_equal(counts.users_live[], 0)


def _key_probe(json: Bool = False) raises -> Headers:
    var h = _key(json)
    h.add("X-Probe", "p")
    return h^


def test_three_slots_without_the_user() raises:
    var counts = Counts()
    var app = make_keyed(counts)
    var client = TestClient(app)
    var r = client.get("/k/ih/1?b=2", headers=_key_probe())
    assert_equal(r.text(), "1,2 2 X-Key=k1 X-Probe=p")
    assert_equal(client.get("/k/ih/1?b=x").status, 401)
    assert_equal(client.get("/k/ih/1?b=x", headers=_key()).status, 400)
    assert_equal(client.get("/k/ih/1", headers=_key()).status, 400)
    r = client.post("/k/ij/3/4", '{"text":"hi"}', headers=_key(True))
    assert_equal(r.text(), "3,4 hi")
    assert_equal(
        client.post("/k/ij/3/x", "{bad", headers=_no_token_json()).status, 401
    )
    assert_equal(
        client.post("/k/ij/3/4", "{bad", headers=_key(True)).status, 400
    )
    assert_equal(
        client.post("/k/ij/3/4", '{"text":"hi"}', headers=_key()).status, 415
    )
    r = client.get("/k/sih/5/6", headers=_key_probe())
    assert_equal(r.text(), "20 5,6 2 X-Key=k1 X-Probe=p")
    assert_equal(client.get("/k/sih/5/%zz").status, 401)
    assert_equal(client.get("/k/sih/5/%zz", headers=_key()).status, 400)
    # The guard made a user for each of the 8 keyed requests; none of these
    # handlers takes it, and each is dropped.
    assert_equal(counts.users_made[], 8)
    assert_equal(counts.users_live[], 0)


def test_route_value_records_behind_the_guard() raises:
    var counts = Counts()
    var app = make_keyed(counts)
    var client = TestClient(app)
    var r = client.get("/k/r/7/web/9", headers=_key_probe())
    assert_equal(r.text(), "ada 7/web/9 2 X-Key=k1 X-Probe=p")
    assert_equal(client.get("/k/r/7/web/x").status, 401)
    assert_equal(client.get("/k/r/7/web/x", headers=_key()).status, 400)
    assert_equal(client.get("/k/r/7/%zz/9").status, 401)
    assert_equal(client.get("/k/r/7/%zz/9", headers=_key()).status, 400)
    r = client.post("/k/r/7/a%20b/9", '{"text":"hi"}', headers=_key(True))
    assert_equal(r.text(), "7/a b/9 hi")
    assert_equal(
        client.post("/k/r/7/web/9", "{bad", headers=_key(True)).status, 400
    )
    r = client.put("/k/r/7/web/9", '{"text":"yo"}', headers=_key_probe(True))
    assert_equal(
        r.text(),
        "ada 7/web/9 yo 3 X-Key=k1 Content-Type=application/json X-Probe=p",
    )
    assert_equal(
        client.put(
            "/k/r/x/web/9", '{"text":"yo"}', headers=_no_token_json()
        ).status,
        401,
    )
    assert_equal(
        client.put("/k/r/x/web/9", '{"text":"yo"}', headers=_key(True)).status,
        400,
    )
    assert_equal(
        client.get("/k/f/1?q=a&limit=5", headers=_key()).text(), "ada 1 a 5"
    )
    assert_equal(client.get("/k/f/1?q=a", headers=_key()).text(), "ada 1 a -")
    assert_equal(client.get("/k/f/1?limit=5").status, 401)
    assert_equal(client.get("/k/f/1?limit=5", headers=_key()).status, 400)
    assert_equal(client.get("/k/f/1?q=a&limit=x", headers=_key()).status, 400)
    assert_equal(counts.users_live[], 0)


def test_a_guard_that_makes_the_user_then_raises() raises:
    var counts = Counts()
    var app = make_keyed(counts)
    var client = TestClient(app)
    var h = _key(True)
    h.add("X-Revoked", "1")
    assert_equal(
        client.post("/k/echo/5", '{"text":"hi"}', headers=h^).status, 403
    )
    var g = _key()
    g.add("X-Revoked", "1")
    assert_equal(client.get("/k/ping", headers=g^).status, 403)
    assert_equal(counts.users_made[], 2)
    assert_equal(counts.users_live[], 0)


def test_guard_state_and_handler_state_dropped_once() raises:
    var counts = Counts()
    var app = make_keyed(counts)
    _ = TestClient(app).get("/k/ping", headers=_key())
    assert_equal(counts.configs_live[], 1)
    assert_equal(counts.services_live[], 1)
    _ = app^
    assert_equal(counts.configs_live[], 0)
    assert_equal(counts.services_live[], 0)


def fields_guard(svc: State[Service], headers: Headers) -> User:
    """Admits everyone, naming the user after the fields it received."""
    return User(_fields(headers), svc[].counts)


def me_text(user: User) -> String:
    return user.name


def test_the_guard_receives_every_field_in_order() raises:
    var counts = Counts()
    var svc = State(Service(Dict[String, String](), 20, counts))
    var app = App()
    var g = Group(fields_guard, svc)
    g.get["/fields"](me_text)
    g.post["/fields"](me_text)
    app.mount(g^)
    var client = TestClient(app)
    var h = Headers()
    h.add("X-B", "2")
    h.add("x-a", "1")
    h.add("X-B", "3")
    assert_equal(
        client.get("/fields", headers=h.copy()).text(),
        "3 X-B=2 x-a=1 X-B=3",
    )
    assert_equal(
        client.post("/fields", "body", headers=h^).text(),
        "3 X-B=2 x-a=1 X-B=3",
    )
    assert_equal(counts.users_live[], 0)


def failing_guard(svc: State[Service], headers: Headers) raises -> User:
    """A guard with bare `raises`: its error is never mapped."""
    raise Error("token store detail")


def test_a_guard_error_without_a_conversion_is_the_fixed_500() raises:
    var counts = Counts()
    var svc = State(Service(Dict[String, String](), 20, counts))
    var app = App()
    var g = Group(failing_guard, svc)
    g.get["/notes/{id}"](get_note, svc)
    app.mount(g^)
    var client = TestClient(app)
    for path in ["/notes/1", "/notes/x"]:
        var r = client.get(path)
        assert_equal(r.status, 500)
        assert_equal(r.text(), "Internal Server Error")
        var failure = r.failure()
        assert_true(Bool(failure))
        assert_equal(failure.value().source, "handler")
        assert_equal(failure.value().message, "token store detail")
    assert_equal(counts.handler_calls[], 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
