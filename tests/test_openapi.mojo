# M3-092: `App.openapi`'s exact output for each request slot, body, result
# and JSON field kind, each addition and each refusal
# (docs/reference/openapi.md). `test_document_and_exchanges` sends requests
# through `TestClient` to an `App` that has every kind at once; with
# MUNTIN_OPENAPI_OUT set, it writes its document to `<dir>/openapi.json`
# and each exchange to `<dir>/exchanges.jsonl`, which
# `scripts/validate_openapi.py` checks against the document. Some of those
# exchanges pin the known gaps of M3-091 (docs/ARCHITECTURE.md's revisit
# index): JSON Schema's `integer` takes `1.0`, and a hand-written reader's
# schema is `{}`.
# Build flags (scripts/build_one.sh): -D MUNTIN_OPENAPI

from std.collections import Dict
from std.os import getenv
from std.testing import assert_equal, assert_true, TestSuite

from muntin import (
    App,
    FromBody,
    FromBytes,
    FromJson,
    FromRouteValue,
    Group,
    Headers,
    Json,
    JsonFields,
    JsonValue,
    JsonWriter,
    Request,
    Response,
    RouteValues,
    State,
    ToErrorResponse,
    ToJson,
    ToResponse,
    WithHeaders,
)
from muntin.testing import TestClient
from openapi_handlers import delete_note, named_pair


@fieldwise_init
struct Place(Copyable, JsonFields):
    var city: String
    var lat: Float64


@fieldwise_init
struct Note(Copyable, JsonFields):
    var id: Int
    var text: String
    var tags: List[String]
    var done: Bool
    var place: Optional[Place]
    var score: Optional[Float64]


@fieldwise_init
struct NewNote(Copyable, JsonFields):
    var text: String
    var tags: List[String]
    var place: Optional[Place]


@fieldwise_init
struct Version(Copyable, FromJson, ToJson):
    """Hand-written both ways: a bare number."""

    var v: Int

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        return Self(value.int())

    def write_json(self, mut out: JsonWriter) raises:
        out.int(self.v)


@fieldwise_init
struct Envelope(Copyable, JsonFields):
    var version: Version
    var notes: List[Note]


@fieldwise_init
struct Slug(FromRouteValue):
    var text: String

    @staticmethod
    def from_route_value(value: String) raises -> Self:
        return Self(value)


@fieldwise_init
struct TaskAt(RouteValues):
    var org: Int
    var task: String
    var limit: Optional[Int]


struct Line(FromBody):
    var text: String

    def __init__(out self, var text: String):
        self.text = text^

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


struct Blob(FromBytes):
    comptime max_bytes = 64
    var n: Int

    def __init__(out self, n: Int):
        self.n = n

    @staticmethod
    def from_bytes(body: List[UInt8]) raises -> Self:
        return Self(len(body))


@fieldwise_init
struct Store(Movable):
    var prefix: String


@fieldwise_init
struct Member(Movable):
    var name: String


def _note(id: Int) -> Note:
    var tags = List[String]()
    tags.append("a")
    return Note(id, "first", tags^, False, Optional(Place("Kyoto", 35.0)), None)


def get_note(id: Int) -> Json[Note]:
    return Json(_note(id))


def list_notes(tag: Optional[String], limit: Optional[Int]) -> Json[List[Note]]:
    var l = List[Note]()
    l.append(_note(1))
    var n = _note(2)
    n.place = None
    n.score = Optional(0.5)
    l.append(n^)
    return Json(l^)


def create_note(var body: Json[NewNote]) -> Json[Note]:
    var b = body^.take()
    return Json(
        Note(3, b.text, b.tags.copy(), False, b.place.copy(), None), status=201
    )


def by_slug(slug: Slug) -> Json[Optional[Note]]:
    if slug.text == "none":
        return Json(Optional[Note]())
    return Json(Optional(_note(4)))


def get_task(at: TaskAt) -> String:
    return "task"


def put_line(id: Int, line: Line) -> String:
    return line.text


def upload(blob: Blob) -> Response:
    return Response.text(String(blob.n))


def upload_with_headers(var input: WithHeaders[Blob]) -> Response:
    return Response.text(String(input.body.n))


@fieldwise_init
struct Count(Copyable, JsonFields):
    var n: Int


def count(var body: Json[Count]) -> Json[Count]:
    return body^


def search(q: String) -> String:
    return q


def missing() -> Json[Place]:
    return Json(Place("nowhere", 0.0), status=404)


def delete_place(id: Int) -> Response:
    return Response(204, "")


def delete_old_place(id: Int) -> Json[Place]:
    # A 204 carries no body (M3-093), which the derived `2XX` describes
    # with content: `_additions` describes the 204.
    return Json(Place("gone", 0.0), status=204)


def raw(req: Request) -> Response:
    return Response.text("raw")


def with_headers(var input: WithHeaders[Json[NewNote]]) -> Json[Envelope]:
    var notes = List[Note]()
    notes.append(_note(5))
    return Json(Envelope(Version(2), notes^))


def headers_only(h: Headers) -> String:
    return "h"


def stateful(store: State[Store], id: Int) -> String:
    return store[].prefix + String(id)


def versioned(var body: Json[Version]) -> Json[List[Version]]:
    var l = List[Version]()
    l.append(body^.take())
    return Json(l^)


@fieldwise_init
struct Unauthorized(ToErrorResponse):
    def to_error_response(deinit self) -> Response:
        return Response.text("Unauthorized", status=401)


def guard(s: State[Store], h: Headers) raises Unauthorized -> Member:
    """The `member` scheme `_additions` declares: an `X-Member` field."""
    var name = h.get("x-member").or_else("")
    if name.byte_length() == 0:
        raise Unauthorized()
    return Member(name)


def me(m: Member) -> String:
    return m.name


def member_note(m: Member, id: Int) -> Json[Note]:
    return Json(_note(id))


def make_app() -> App:
    var store = State(Store("n"))
    var app = App()
    app.get["/notes/{id}"](get_note)
    app.get["/notes?{tag}&{limit}"](list_notes)
    app.post["/notes"](create_note)
    app.delete["/notes/{id}"](delete_note)
    app.get["/by-slug/{slug}"](by_slug)
    app.get["/orgs/{org}/tasks/{task}?{limit}"](get_task)
    app.put["/lines/{id}"](put_line)
    app.post["/upload"](upload)
    app.post["/upload-with-headers"](upload_with_headers)
    app.get["/raw"](raw)
    app.get["/missing"](missing)
    app.get["/search?{q}"](search)
    app.post["/counts"](count)
    app.delete["/places/{id}"](delete_place)
    app.delete["/old-places/{id}"](delete_old_place)
    app.post["/envelope"](with_headers)
    app.get["/headers"](headers_only)
    app.get["/stateful/{id}"](stateful, store)
    app.post["/versions"](versioned)
    var members = Group(guard, store)
    members.get["/me"](me)
    members.get["/members/notes/{id}"](member_note)
    app.mount(members^)
    return app^


def _json_headers() -> Headers:
    var h = Headers()
    try:
        h.add("Content-Type", "application/json")
    except:
        pass
    return h^


struct _Log(Movable):
    """Every exchange `test_document_and_exchanges` sends, for
    `scripts/validate_openapi.py`."""

    var lines: List[String]

    def __init__(out self):
        self.lines = List[String]()

    def send(
        mut self,
        client: TestClient,
        method: String,
        target: String,
        body: String = "",
        json: Bool = False,
        member: String = "",
    ) raises -> Response:
        var h = _json_headers() if json else Headers()
        if member:
            h.add("X-Member", member)
        var r: Response
        if method == "GET":
            r = client.get(target, headers=h^)
        elif method == "DELETE":
            r = client.delete(target, headers=h^)
        elif method == "PUT":
            r = client.put(target, body, headers=h^)
        elif method == "POST":
            r = client.post(target, body, headers=h^)
        else:
            raise Error("_Log.send: no " + method)
        var out = JsonWriter()
        out.begin_object()
        out.field("method", method)
        out.field("target", target)
        out.field("body", body)
        out.field("json", json)
        out.field("member", member)
        out.field("status", r.status)
        out.field("response", String(unsafe_from_utf8=r.body))
        var ct = r.headers.get("content-type")
        out.field("content_type", ct.or_else(""))
        out.end_object()
        self.lines.append(out^._finish())
        return r^


def _additions() -> Dict[String, String]:
    """What the types cannot say: the credential the guard checks, the
    statuses it and a `Json` handler answer (an explicit 404 or 401 takes
    precedence over the derived `2XX`), and the 204 of a `Response` and of
    a `Json` handler."""
    var member = (
        '{"security":[{"member":[]}],"responses":{"401":{"description":'
        + '"No X-Member field","content":{"*/*":{"schema":'
        + '{"const":"Unauthorized"}}}}}}'
    )
    var place = (
        '{"type":"object","properties":{"city":{"type":"string"},'
        + '"lat":{"type":"number"}},"required":["city","lat"]}'
    )
    var ops = Dict[String, String]()
    ops["GET /me"] = member
    ops["GET /members/notes/{id}"] = member
    ops["GET /missing"] = (
        '{"summary":"Always missing","responses":{"404":{"description":'
        + '"No place","content":{"application/json":{"schema":'
        + place
        + "}}}}}"
    )
    var deleted = '{"responses":{"204":{"description":"Deleted"}}}'
    ops["DELETE /places/{id}"] = deleted
    ops["DELETE /old-places/{id}"] = deleted
    return ops^


def test_document_and_exchanges() raises:
    var app = make_app()
    var doc = app.openapi(
        title="Notes",
        version="0.1.0",
        document=(
            '{"info":{"summary":"Every kind at once"},"components":'
            + '{"securitySchemes":{"member":{"type":"apiKey","in":"header",'
            + '"name":"X-Member"}}}}'
        ),
        operations=_additions(),
    )
    assert_true(doc.startswith('{"openapi":"3.1.0","info":{"title":"Notes"'))
    var client = TestClient(app)
    var log = _Log()
    # Admitted by the document; each `Json` answer meets its schema.
    assert_equal(log.send(client, "GET", "/notes/7").status, 200)
    assert_equal(log.send(client, "GET", "/notes/-3").status, 200)
    assert_equal(log.send(client, "GET", "/notes").status, 200)
    assert_equal(log.send(client, "GET", "/notes?tag=a&limit=2").status, 200)
    # An optional value's empty text, with or without `=`, is `None`.
    assert_equal(log.send(client, "GET", "/notes?tag=").status, 200)
    assert_equal(log.send(client, "GET", "/notes?tag&limit=").status, 200)
    for body in [
        '{"text":"t","tags":["x"],"place":null}',
        '{"text":"t","tags":[]}',
        '{"text":"t","tags":[],"place":{"city":"Oslo","lat":59.9},"x":1}',
    ]:
        assert_equal(
            log.send(client, "POST", "/notes", String(body), True).status, 201
        )
    assert_equal(log.send(client, "DELETE", "/notes/7").status, 200)
    assert_equal(log.send(client, "GET", "/by-slug/none").status, 200)
    assert_equal(log.send(client, "GET", "/by-slug/x").status, 200)
    assert_equal(log.send(client, "GET", "/orgs/1/tasks/t?limit=5").status, 200)
    # A text or binary body may be empty: its type decides.
    assert_equal(log.send(client, "PUT", "/lines/7", "").status, 200)
    assert_equal(log.send(client, "PUT", "/lines/7", "x").status, 200)
    assert_equal(log.send(client, "POST", "/upload", "").status, 200)
    assert_equal(log.send(client, "POST", "/upload-with-headers").status, 200)
    var env = '{"text":"t","tags":[]}'
    assert_equal(log.send(client, "POST", "/envelope", env, True).status, 200)
    assert_equal(log.send(client, "POST", "/versions", "3", True).status, 200)
    assert_equal(log.send(client, "GET", "/stateful/4").status, 200)
    # The guard enforces the `security` the additions declare.
    assert_equal(log.send(client, "GET", "/me", member="ada").status, 200)
    assert_equal(log.send(client, "GET", "/me").status, 401)
    var mn = "/members/notes/3"
    assert_equal(log.send(client, "GET", mn, member="ada").status, 200)
    assert_equal(log.send(client, "GET", mn).status, 401)
    assert_equal(log.send(client, "GET", "/search?q=a%20b").status, 200)
    # Refused by the document and by Muntin (400 or 415).
    for body in [
        '{"tags":[]}',
        '{"text":1,"tags":[]}',
        '{"text":"t","tags":[1]}',
        '{"text":"t","tags":[],"place":{"city":"x"}}',
        "",
    ]:
        assert_equal(
            log.send(client, "POST", "/notes", String(body), True).status, 400
        )
    assert_equal(log.send(client, "POST", "/notes", env).status, 415)
    assert_equal(log.send(client, "GET", "/notes/x").status, 400)
    assert_equal(log.send(client, "GET", "/notes/+7").status, 400)
    assert_equal(
        log.send(client, "GET", "/notes/99999999999999999999").status, 400
    )
    assert_equal(log.send(client, "GET", "/notes?limit=x").status, 400)
    assert_equal(log.send(client, "GET", "/search?q=").status, 400)
    assert_equal(log.send(client, "GET", "/search").status, 400)
    assert_equal(log.send(client, "GET", "/orgs/1/tasks/t?limit=y").status, 400)
    # Known gaps the validator expects (the record's): JSON Schema's
    # `integer` takes `1.0` and `1e2`, and `number` a literal past
    # `Float64`'s range, which the reader refuses; a hand-written reader's
    # `{}`. A 404 `Json` answer meets the entry `_additions` gives it, as
    # the bodiless 204 of a `Response` and of a `Json` do.
    assert_equal(
        log.send(client, "POST", "/counts", '{"n":1}', True).status, 200
    )
    assert_equal(
        log.send(client, "POST", "/counts", '{"n":1.0}', True).status, 400
    )
    assert_equal(
        log.send(client, "POST", "/counts", '{"n":1e2}', True).status, 400
    )
    var far = '{"text":"t","tags":[],"place":{"city":"x","lat":1e400}}'
    assert_equal(log.send(client, "POST", "/notes", far, True).status, 400)
    assert_equal(log.send(client, "POST", "/versions", "3.0", True).status, 400)
    assert_equal(log.send(client, "GET", "/missing").status, 404)
    assert_equal(log.send(client, "DELETE", "/places/1").status, 204)
    var old = log.send(client, "DELETE", "/old-places/1")
    assert_equal(old.status, 204)
    assert_equal(len(old.body), 0)  # a `Json` 204 carries no body (M3-093)
    # A binary body, bare or carried, has no schema; a route string is
    # non-empty.
    assert_equal(
        doc.count('"requestBody":{"required":false,"content":{"*/*":{}}}'), 2
    )
    assert_true(
        doc.find(
            '{"name":"slug","in":"path","required":true,"schema":'
            + '{"type":"string","minLength":1}}'
        )
        >= 0
    )
    var dir = getenv("MUNTIN_OPENAPI_OUT")
    if dir:
        with open(dir + "/openapi.json", "w") as f:
            f.write(doc)
        with open(dir + "/exchanges.jsonl", "w") as f:
            for line in log.lines:
                f.write(line + "\n")


def test_exact_operation() raises:
    var app = App()
    app.get["/notes/{id}?{tag}"](_get_tagged)
    assert_equal(
        app.openapi(title="T", version="1"),
        '{"openapi":"3.1.0","info":{"title":"T","version":"1"},"paths":'
        + '{"/notes/{id}":{"get":{"parameters":['
        + '{"name":"id","in":"path","required":true,"schema":'
        + '{"type":"integer","format":"int64","minimum":-9223372036854775808,'
        + '"maximum":9223372036854775807}},'
        + '{"name":"tag","in":"query","required":false,"allowEmptyValue":true,'
        + '"description":"An empty value is the same as an absent one.",'
        + '"schema":{"type":"string","minLength":1}}],'
        + '"responses":{"2XX":{"description":"The handler\'s JSON'
        + ' value","content":{"application/json":{"schema":'
        + '{"type":"object","properties":{"city":{"type":"string"},'
        + '"lat":{"type":"number","format":"double"}},'
        + '"required":["city","lat"],"additionalProperties":false}}}}}}}}}',
    )


def _get_tagged(id: Int, tag: Optional[String]) -> Json[Place]:
    return Json(Place("Kyoto", 35.0))


def _a(id: Int) -> String:
    return "a"


def _b(name: String) -> String:
    return "b"


def _c(a: Int, b: Int) -> String:
    return "c"


def test_templates_that_differ_only_in_names_raise() raises:
    var app = App()
    app.get["/users/{id}"](_a)
    app.delete["/users/{name}"](_b)
    try:
        _ = app.openapi(title="T", version="1")
    except e:
        assert_true(String(e).find("differ only in placeholder names") >= 0)
        return
    raise Error("no raise")


def test_repeated_path_name_raises() raises:
    var app = App()
    app.get["/pairs/{id}/{id}"](_c)
    try:
        _ = app.openapi(title="T", version="1")
    except e:
        assert_true(String(e).find("repeats the placeholder {id}") >= 0)
        return
    raise Error("no raise")


def _d(key: Optional[String]) -> String:
    return "d"


def test_percent_encoded_query_key_raises() raises:
    var app = App()
    app.get["/f?{filter[name]}"](_d)
    try:
        _ = app.openapi(title="T", version="1")
    except e:
        assert_true(String(e).find("may not send the query key") >= 0)
        return
    raise Error("no raise")


def _e() -> String:
    return "e"


def test_percent_encoded_segment_raises() raises:
    var app = App()
    app.get["/hello world"](_e)
    try:
        _ = app.openapi(title="T", version="1")
    except e:
        assert_true(String(e).find("may not send the segment") >= 0)
        return
    raise Error("no raise")


def _refused(var app: App) raises -> Bool:
    try:
        _ = app.openapi(title="T", version="1")
    except:
        return True
    return False


def test_sent_as_written_boundaries() raises:
    # Sub-delimiters, `:`, `@` and `~` in a path segment are sent as
    # written; in a query key, `~` and sub-delimiters are not, nor are the
    # dot segments, which a client removes.
    var a = App()
    a.get["/a:b@c/x;y/~k/p!q(r)*s+t,u=v$w&z'"](_e)
    assert_true(not _refused(a^))
    var b = App()
    b.get["/f?{a,b}"](_d)
    assert_true(_refused(b^))
    var c = App()
    c.get["/f?{a~b}"](_d)
    assert_true(_refused(c^))
    var d = App()
    d.get["/a/./b"](_e)
    assert_true(_refused(d^))
    var e = App()
    e.get["/a/../b"](_e)
    assert_true(_refused(e^))
    var f = App()
    f.get["/caf%C3%A9"](_e)
    assert_true(not _refused(f^))
    var g = App()
    g.get["/caf%C3%G9"](_e)
    assert_true(_refused(g^))
    # Letters of either case, digits, `-`, `.` and `_` are sent as written
    # in both; `%HH` only in a segment.
    var h = App()
    h.get["/V1.2/open_API-x.json?{Page_size-2.x}"](_d)
    assert_true(not _refused(h^))
    var i = App()
    i.get["/f?{a%41}"](_d)
    assert_true(_refused(i^))
    # A dot segment written with `%2e` or `%2E` is one too.
    var j = App()
    j.get["/a/%2e/b"](_e)
    assert_true(_refused(j^))
    var k = App()
    k.get["/a/%2E%2e/b"](_e)
    assert_true(_refused(k^))
    var l = App()
    l.get["/a/.%2E/b"](_e)
    assert_true(_refused(l^))
    var m = App()
    m.get["/a/%2e./b"](_e)
    assert_true(_refused(m^))
    # `%2e` beside other text is no dot segment.
    var n = App()
    n.get["/a/%2ex/b"](_e)
    assert_true(not _refused(n^))


def _find(id: Int) -> Json[Place]:
    return Json(Place("nowhere", 0.0), status=404)


def _make(body: Json[Place]) -> String:
    return "made"


def test_additions_merged_as_written() raises:
    var app = App()
    app.get["/places/{id}"](_find)
    app.get["/raw"](raw)
    var ops = Dict[String, String]()
    ops["GET /places/{id}"] = (
        '{"summary":"Find","responses":{"404":{"description":"No place"}},'
        + '"x-rate":1.50,"x-n":[-0,1e3,true,false,null]}'
    )
    # A raw handler reads the body itself: no derived `requestBody`.
    ops["GET /raw"] = '{"requestBody":{"content":{"text/plain":{}}}}'
    var doc = app.openapi(
        title="T",
        version="1",
        document='{"info":{"summary":"S"},"servers":[{"url":"/v1"}]}',
        operations=ops^,
    )
    assert_equal(
        doc,
        '{"openapi":"3.1.0","info":{"title":"T","version":"1","summary":"S"},'
        + '"paths":{"/places/{id}":{"get":{"parameters":['
        + '{"name":"id","in":"path","required":true,"schema":'
        + '{"type":"integer","format":"int64","minimum":-9223372036854775808,'
        + '"maximum":9223372036854775807}}],'
        + '"responses":{"2XX":{"description":"The handler\'s JSON'
        + ' value","content":{"application/json":{"schema":'
        + '{"type":"object","properties":{"city":{"type":"string"},'
        + '"lat":{"type":"number","format":"double"}},'
        + '"required":["city","lat"],"additionalProperties":false}}}},'
        + '"404":{"description":"No place"}},"summary":"Find",'
        + '"x-rate":1.50,"x-n":[-0,1e3,true,false,null]}},'
        + '"/raw":{"get":{"parameters":[],"responses":{"default":'
        + '{"description":"Not described: the handler\'s response"}},'
        + '"requestBody":{"content":{"text/plain":{}}}}}},'
        + '"servers":[{"url":"/v1"}]}',
    )


def _refuses_addition(
    document: String, key: String, text: String, message: String
) raises:
    var app = App()
    app.post["/places"](_make)
    var ops = Dict[String, String]()
    if key:
        ops[key] = text
    try:
        _ = app.openapi(
            title="T", version="1", document=document, operations=ops^
        )
    except e:
        assert_equal(String(e), message)
        return
    raise Error("not refused: " + key + " " + text)


def test_additions_that_repeat_or_miss_raise() raises:
    var op = "POST /places"
    _refuses_addition(
        "", "GET /nowhere", "{}", "openapi: operations: no route GET /nowhere"
    )
    _refuses_addition(
        "",
        op,
        "[1]",
        "openapi: operations[POST /places] is not a JSON object",
    )
    _refuses_addition(
        "",
        op,
        "{",
        "openapi: operations[POST /places] is not JSON:"
        + " invalid JSON: expected member name",
    )
    _refuses_addition(
        "",
        op,
        '{"parameters":{}}',
        "openapi: operations[POST /places]: parameters is not a JSON array",
    )
    _refuses_addition(
        "",
        op,
        '{"requestBody":{}}',
        "openapi: operations[POST /places]: requestBody is derived",
    )
    _refuses_addition(
        "",
        op,
        '{"responses":{"200":{}}}',
        "openapi: operations[POST /places]: 200 is derived",
    )
    _refuses_addition(
        '{"info":{"title":"U"}}',
        "",
        "",
        "openapi: document: info: title is derived",
    )
    _refuses_addition(
        '{"paths":{}}', "", "", "openapi: document: paths is derived"
    )
    _refuses_addition('"x"', "", "", "openapi: document is not a JSON object")
    _refuses_addition(
        '{"openapi":"3.0.3"}', "", "", "openapi: document: openapi is derived"
    )
    _refuses_addition(
        '{"info":{"version":"2"}}',
        "",
        "",
        "openapi: document: info: version is derived",
    )
    _refuses_addition(
        '{"info":[]}', "", "", "openapi: document: info: not a JSON object"
    )
    _refuses_addition(
        "",
        op,
        '{"summary":"a","summary":"b"}',
        "openapi: operations[POST /places] is not JSON:"
        + " invalid JSON: duplicate member",
    )
    _refuses_addition(
        "",
        op,
        '{"responses":[]}',
        "openapi: operations[POST /places]: not a JSON object",
    )
    # Additions are read with the JSON reader's limits.
    var deep = '{"x":' + String("[") * 100 + String("]") * 100
    var big = '{"x":"' + String("a") * 1_048_576
    _refuses_addition(
        deep + "}",
        "",
        "",
        "openapi: document is not JSON: invalid JSON: nesting too deep",
    )
    _refuses_addition(
        big + '"}', "", "", "openapi: document is not JSON: JSON body too large"
    )


def _refuses_result(var app: App, key: String, status: String) raises:
    var ops = Dict[String, String]()
    ops[key] = '{"responses":{"' + status + '":{"description":"x"}}}'
    try:
        _ = app.openapi(title="T", version="1", operations=ops^)
    except e:
        assert_equal(
            String(e),
            "openapi: operations[" + key + "]: " + status + " is derived",
        )
        return
    raise Error("not refused: " + key + " " + status)


def test_additions_that_repeat_a_result_raise() raises:
    # The status the result gives is derived, whatever the result's kind.
    var a = App()
    a.get["/places/{id}"](_find)
    _refuses_result(a^, "GET /places/{id}", "2XX")
    var b = App()
    b.get["/raw"](raw)
    _refuses_result(b^, "GET /raw", "default")
    var c = App()
    c.get["/headers"](headers_only)
    _refuses_result(c^, "GET /headers", "200")


def test_same_path_two_methods_one_path_item() raises:
    var app = App()
    app.get["/users/{id}"](_a)
    app.delete["/users/{id}"](_a)
    var doc = app.openapi(title="T", version="1")
    assert_true(doc.find('"/users/{id}":{"get":') >= 0)
    assert_true(doc.find('}},"delete":') >= 0)


# Each kind's exact output. `_only` returns the one operation of a
# one-route `App`'s document, after checking the document around it.


def _only(var app: App, path: String, method: String) raises -> String:
    var doc = app.openapi(title="T", version="1")
    var head = (
        '{"openapi":"3.1.0","info":{"title":"T","version":"1"},"paths":{"'
        + path
        + '":{"'
        + method
        + '":'
    )
    assert_true(doc.startswith(head), doc)
    assert_true(doc.endswith("}}}"), doc)
    return String(doc[byte = head.byte_length() : doc.byte_length() - 3])


def _int() -> String:
    return (
        '{"type":"integer","format":"int64","minimum":-9223372036854775808,'
        + '"maximum":9223372036854775807}'
    )


def _route_string() -> String:
    return '{"type":"string","minLength":1}'


def _param(name: String, place: String, schema: String) -> String:
    return (
        '{"name":"'
        + name
        + '","in":"'
        + place
        + '","required":true,"schema":'
        + schema
        + "}"
    )


def _optional(name: String, schema: String) -> String:
    return (
        '{"name":"'
        + name
        + '","in":"query","required":false,"allowEmptyValue":true,'
        + '"description":"An empty value is the same as an absent one.",'
        + '"schema":'
        + schema
        + "}"
    )


def _text() -> String:
    return (
        '"responses":{"200":{"description":"The handler\'s text","content":'
        + '{"*/*":{"schema":{"type":"string"}}}}}'
    )


def _undescribed() -> String:
    return (
        '"responses":{"default":{"description":"Not described: the'
        + " handler's response\"}}"
    )


def _json(schema: String) -> String:
    return (
        '"responses":{"2XX":{"description":"The handler\'s JSON value",'
        + '"content":{"application/json":{"schema":'
        + schema
        + "}}}}"
    )


def _json_body(schema: String) -> String:
    return (
        '"requestBody":{"required":true,"content":{"application/json":'
        + '{"schema":'
        + schema
        + "}}}"
    )


def _text_body() -> String:
    return (
        '"requestBody":{"required":false,"content":{"*/*":{"schema":'
        + '{"type":"string"}}}}'
    )


def _bytes_body() -> String:
    return '"requestBody":{"required":false,"content":{"*/*":{}}}'


def _place_read() -> String:
    return (
        '{"type":"object","properties":{"city":{"type":"string"},'
        + '"lat":{"type":"number","format":"double"}},'
        + '"required":["city","lat"]}'
    )


def _place_written() -> String:
    return (
        '{"type":"object","properties":{"city":{"type":"string"},'
        + '"lat":{"type":"number","format":"double"}},'
        + '"required":["city","lat"],"additionalProperties":false}'
    )


def _of_int(n: Int) -> String:
    return "i"


def _of_strings(name: String, slug: Slug) -> StaticString:
    return "s"


def _of_optionals(n: Optional[Int], t: Optional[String]) -> String:
    return "o"


def test_route_values() raises:
    var a = App()
    a.get["/n/{n}"](_of_int)
    assert_equal(
        _only(a^, "/n/{n}", "get"),
        '{"parameters":[' + _param("n", "path", _int()) + "]," + _text() + "}",
    )
    # `String` and a `FromRouteValue` read the decoded text, never empty;
    # a `StaticString` result is text too.
    var b = App()
    b.get["/s/{name}?{slug}"](_of_strings)
    assert_equal(
        _only(b^, "/s/{name}", "get"),
        '{"parameters":['
        + _param("name", "path", _route_string())
        + ","
        + _param("slug", "query", _route_string())
        + "],"
        + _text()
        + "}",
    )
    var c = App()
    c.get["/o?{n}&{t}"](_of_optionals)
    assert_equal(
        _only(c^, "/o", "get"),
        '{"parameters":['
        + _optional("n", _int())
        + ","
        + _optional("t", _route_string())
        + "],"
        + _text()
        + "}",
    )


def test_record_and_named_values() raises:
    var a = App()
    a.get["/orgs/{org}/tasks/{task}?{limit}"](get_task)
    assert_equal(
        _only(a^, "/orgs/{org}/tasks/{task}", "get"),
        '{"parameters":['
        + _param("org", "path", _int())
        + ","
        + _param("task", "path", _route_string())
        + ","
        + _optional("limit", _int())
        + "],"
        + _text()
        + "}",
    )
    var b = App()
    b.get["/orgs/{org}/{slug}"](named_pair)
    assert_equal(
        _only(b^, "/orgs/{org}/{slug}", "get"),
        '{"parameters":['
        + _param("org", "path", _int())
        + ","
        + _param("slug", "path", _route_string())
        + "],"
        + _text()
        + "}",
    )


def _of_line(var line: WithHeaders[Line]) -> String:
    return line.body.text


def _of_place(var place: WithHeaders[Json[Place]]) -> String:
    return "p"


def test_bodies() raises:
    # Only a `Json[T]` body is required; a text body is a string of any
    # media type, a binary one has no schema. A carrier's body is its
    # carried type's.
    var a = App()
    a.post["/places"](_make)
    assert_equal(
        _only(a^, "/places", "post"),
        '{"parameters":[],' + _json_body(_place_read()) + "," + _text() + "}",
    )
    var b = App()
    b.post["/places"](_of_place)
    assert_equal(
        _only(b^, "/places", "post"),
        '{"parameters":[],' + _json_body(_place_read()) + "," + _text() + "}",
    )
    var c = App()
    c.put["/lines/{id}"](put_line)
    assert_equal(
        _only(c^, "/lines/{id}", "put"),
        '{"parameters":['
        + _param("id", "path", _int())
        + "],"
        + _text_body()
        + ","
        + _text()
        + "}",
    )
    var d = App()
    d.post["/lines"](_of_line)
    assert_equal(
        _only(d^, "/lines", "post"),
        '{"parameters":[],' + _text_body() + "," + _text() + "}",
    )
    var e = App()
    e.post["/upload"](upload)
    assert_equal(
        _only(e^, "/upload", "post"),
        '{"parameters":[],' + _bytes_body() + "," + _undescribed() + "}",
    )
    var f = App()
    f.post["/upload"](upload_with_headers)
    assert_equal(
        _only(f^, "/upload", "post"),
        '{"parameters":[],' + _bytes_body() + "," + _undescribed() + "}",
    )


def test_slots_without_parameters() raises:
    # `Headers`, a raw `Request` and `State` add nothing; a raw handler's
    # body is its own (an addition describes it).
    var a = App()
    a.get["/headers"](headers_only)
    assert_equal(
        _only(a^, "/headers", "get"), '{"parameters":[],' + _text() + "}"
    )
    var b = App()
    b.get["/raw"](raw)
    assert_equal(
        _only(b^, "/raw", "get"), '{"parameters":[],' + _undescribed() + "}"
    )
    var c = App()
    c.get["/stateful/{id}"](stateful, State(Store("n")))
    assert_equal(
        _only(c^, "/stateful/{id}", "get"),
        '{"parameters":[' + _param("id", "path", _int()) + "]," + _text() + "}",
    )
    # A guarded route: the guard's own input is not described.
    var d = App()
    var members = Group(guard, State(Store("n")))
    members.get["/me"](me)
    d.mount(members^)
    assert_equal(_only(d^, "/me", "get"), '{"parameters":[],' + _text() + "}")


@fieldwise_init
struct Made(ToResponse):
    def to_response(deinit self) -> Response:
        return Response.text("made", status=201)


def _made() -> Made:
    return Made()


def test_results() raises:
    # A `Json[T]` result is `2XX` of what is written; a `Response` or a
    # `ToResponse` type is undescribed.
    var a = App()
    a.get["/places/{id}"](_find)
    assert_equal(
        _only(a^, "/places/{id}", "get"),
        '{"parameters":['
        + _param("id", "path", _int())
        + "],"
        + _json(_place_written())
        + "}",
    )
    var b = App()
    b.post["/made"](_made)
    assert_equal(
        _only(b^, "/made", "post"), '{"parameters":[],' + _undescribed() + "}"
    )
    var c = App()
    c.delete["/places/{id}"](delete_place)
    assert_equal(
        _only(c^, "/places/{id}", "delete"),
        '{"parameters":['
        + _param("id", "path", _int())
        + "],"
        + _undescribed()
        + "}",
    )


@fieldwise_init
struct Stamp(Copyable, JsonFields, ToJson):
    """Derived when read, hand-written when written: a bare number."""

    var at: Int

    def write_json(self, mut out: JsonWriter) raises:
        out.int(self.at)


@fieldwise_init
struct Every(Copyable, JsonFields):
    var i: Int
    var f: Float64
    var b: Bool
    var s: String
    var place: Place
    var tags: List[String]
    var maybe: Optional[Int]
    var places: Optional[List[Place]]
    var version: Version
    var stamp: Stamp


def _every(var body: Json[Every]) -> Json[Every]:
    return body^


def _every_read() -> String:
    return (
        '{"type":"object","properties":{"i":'
        + _int()
        + ',"f":{"type":"number","format":"double"},"b":{"type":"boolean"},'
        + '"s":{"type":"string"},"place":'
        + _place_read()
        + ',"tags":{"type":"array","items":{"type":"string"}},'
        + '"maybe":{"anyOf":['
        + _int()
        + ',{"type":"null"}]},'
        + '"places":{"anyOf":[{"type":"array","items":'
        + _place_read()
        + '},{"type":"null"}]},"version":{},'
        + '"stamp":{"type":"object","properties":{"at":'
        + _int()
        + '},"required":["at"]}},'
        + '"required":["i","f","b","s","place","tags","version","stamp"]}'
    )


def _every_written() -> String:
    return (
        '{"type":"object","properties":{"i":'
        + _int()
        + ',"f":{"type":"number","format":"double"},"b":{"type":"boolean"},'
        + '"s":{"type":"string"},"place":'
        + _place_written()
        + ',"tags":{"type":"array","items":{"type":"string"}},'
        + '"maybe":{"anyOf":['
        + _int()
        + ',{"type":"null"}]},'
        + '"places":{"anyOf":[{"type":"array","items":'
        + _place_written()
        + '},{"type":"null"}]},"version":{},"stamp":{}},'
        + '"required":["i","f","b","s","place","tags","maybe","places",'
        + '"version","stamp"],"additionalProperties":false}'
    )


def test_field_kinds() raises:
    # Read: an `Optional` member may be absent, other members are allowed;
    # written: every member, no other. A hand-written direction is `{}`.
    var a = App()
    a.post["/every"](_every)
    assert_equal(
        _only(a^, "/every", "post"),
        '{"parameters":[],'
        + _json_body(_every_read())
        + ","
        + _json(_every_written())
        + "}",
    )
    # A top-level `List`, `Optional` and hand-written value.
    var b = App()
    b.get["/by-slug/{slug}"](by_slug)
    assert_true(
        _only(b^, "/by-slug/{slug}", "get").find(
            '"schema":{"anyOf":[{"type":"object"'
        )
        >= 0
    )
    var c = App()
    c.post["/versions"](versioned)
    assert_equal(
        _only(c^, "/versions", "post"),
        '{"parameters":[],'
        + _json_body("{}")
        + ","
        + _json('{"type":"array","items":{}}')
        + "}",
    )


def test_parameters_added_after_the_derived_ones() raises:
    # A raw or `Headers` handler reads what no type says; an addition
    # describes it, but may not repeat a derived parameter's `in` and name.
    var a = App()
    a.get["/raw"](raw)
    var ops = Dict[String, String]()
    ops["GET /raw"] = (
        '{"parameters":[{"name":"X-Id","in":"header","schema":'
        + '{"type":"string"}},{"name":"page","in":"query"}]}'
    )
    assert_equal(
        a.openapi(title="T", version="1", operations=ops^),
        '{"openapi":"3.1.0","info":{"title":"T","version":"1"},"paths":'
        + '{"/raw":{"get":{"parameters":[{"name":"X-Id","in":"header",'
        + '"schema":{"type":"string"}},{"name":"page","in":"query"}],'
        + _undescribed()
        + "}}}}",
    )
    var b = App()
    b.get["/n/{id}?{tag}"](_get_tagged)
    var more = Dict[String, String]()
    more["GET /n/{id}"] = (
        '{"parameters":[{"name":"id","in":"query"},{"name":"tag","in":'
        + '"header"},{"name":"id","in":"header"}]}'
    )
    var doc = b.openapi(title="T", version="1", operations=more^)
    assert_true(
        doc.find(
            '"description":"An empty value is the same as an absent one.",'
            + '"schema":{"type":"string","minLength":1}},{"name":"id",'
            + '"in":"query"},{"name":"tag","in":"header"},'
        )
        >= 0,
        doc,
    )
    for entry in [
        '{"name":"id","in":"path"}',
        '{"in":"query","name":"tag","schema":{}}',
    ]:
        var c = App()
        c.get["/n/{id}?{tag}"](_get_tagged)
        var repeat = Dict[String, String]()
        repeat["GET /n/{id}"] = '{"parameters":[' + String(entry) + "]}"
        try:
            _ = c.openapi(title="T", version="1", operations=repeat^)
        except e:
            assert_true(String(e).find("]: parameter ") >= 0, String(e))
            assert_true(String(e).endswith(" is derived"), String(e))
            continue
        raise Error("not refused: " + String(entry))


def _post_b() -> String:
    return "b"


def _get_b() -> String:
    return "b"


def _yb(y: String) -> String:
    return "yb"


def _xz(x: String, z: Int) -> String:
    return "xz"


def _overlap_refused(var app: App, message: String) raises:
    try:
        _ = app.openapi(title="T", version="1")
    except e:
        assert_equal(String(e), message)
        return
    raise Error("not refused: " + message)


def test_overlapping_paths() raises:
    # `GET /a/b` goes to `/a/{x}`'s route, which OpenAPI resolves to the
    # path `/a/b`: it must have every method `/a/{x}` has.
    var a = App()
    a.get["/a/{x}"](_a)
    a.post["/a/b"](_post_b)
    _overlap_refused(
        a^,
        "openapi: routes /a/{x} and /a/b overlap: OpenAPI resolves a"
        + " request both match to /a/b, which has no GET route",
    )
    var b = App()
    b.get["/a/b"](_get_b)  # the more specific first (M3-053)
    b.get["/a/{x}"](_a)
    b.post["/a/{x}"](_a)
    _overlap_refused(
        b^,
        "openapi: routes /a/{x} and /a/b overlap: OpenAPI resolves a"
        + " request both match to /a/b, which has no POST route",
    )
    # Neither covers the other: OpenAPI resolves `/a/b` to neither.
    var c = App()
    c.get["/a/{x}"](_a)
    c.post["/{y}/b"](_yb)
    _overlap_refused(
        c^,
        "openapi: routes /a/{x} and /{y}/b overlap, and OpenAPI does not say"
        + " which one a request both match resolves to",
    )
    # OpenAPI says nothing about two templated paths, even where Muntin's
    # most specific route is the same for every method.
    var e = App()
    e.get["/a/b/{z}"](_a)  # the more specific first (M3-053)
    e.get["/a/{x}/{z}"](_xz)
    _overlap_refused(
        e^,
        "openapi: routes /a/b/{z} and /a/{x}/{z} overlap, and OpenAPI does"
        + " not say which one a request both match resolves to",
    )
    # The path without a placeholder has every method of the other, or
    # they do not overlap.
    var d = App()
    d.get["/a/b"](_get_b)
    d.get["/a/{x}"](_a)
    d.post["/a/b"](_post_b)
    d.post["/c/d"](_post_b)
    var doc = d.openapi(title="T", version="1")
    assert_true(doc.find('"/a/b":{"get":') >= 0, doc)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
