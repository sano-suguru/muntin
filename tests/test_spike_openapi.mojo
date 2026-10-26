# M3-091 prototype spike: `App.openapi` through every slot kind, result kind
# and JSON field kind, and its refusals. With MUNTIN_OPENAPI_OUT set, it
# writes the document to `<dir>/openapi.json` and each exchange it sends
# through `TestClient` to `<dir>/exchanges.jsonl`, which the pull request's
# validator checks against the document's schemas.
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
    WithHeaders,
)
from muntin.testing import TestClient
from openapi_spike_handlers import delete_note


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
    # `Json.to_response` writes the value whatever the status, so this 204
    # carries a body: a known gap (the record's), which no document fixes.
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
    """Every exchange the spike sends, for the validator
    (prototype-m3-091/validate_openapi.py)."""

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
        else:
            r = client.post(target, body, headers=h^)
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
    precedence over the derived `2XX`), and a `Response` handler's 204."""
    var member = (
        '{"security":[{"member":[]}],"responses":{"401":{"description":'
        + '"No X-Member field"}}}'
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
    ops[
        "DELETE /places/{id}"
    ] = '{"responses":{"204":{"description":"Deleted"}}}'
    return ops^


def test_document_and_exchanges() raises:
    var app = make_app()
    var doc = app.openapi(
        title="Spike",
        version="0.1.0",
        document=(
            '{"info":{"summary":"The M3-091 spike"},"components":'
            + '{"securitySchemes":{"member":{"type":"apiKey","in":"header",'
            + '"name":"X-Member"}}}}'
        ),
        operations=_additions(),
    )
    assert_true(doc.startswith('{"openapi":"3.1.0","info":{"title":"Spike"'))
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
    # `integer` takes `1.0`, which the reader refuses; a hand-written
    # reader's `{}`; a `Json` answer of 204, which carries a body. A 404
    # `Json` answer meets the entry `_additions` gives it, as a bodiless
    # 204 `Response` does.
    assert_equal(
        log.send(client, "POST", "/counts", '{"n":1}', True).status, 200
    )
    assert_equal(
        log.send(client, "POST", "/counts", '{"n":1.0}', True).status, 400
    )
    assert_equal(log.send(client, "POST", "/versions", "3.0", True).status, 400)
    assert_equal(log.send(client, "GET", "/missing").status, 404)
    assert_equal(log.send(client, "DELETE", "/places/1").status, 204)
    assert_equal(log.send(client, "DELETE", "/old-places/1").status, 204)
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


def _find(id: Int) -> Json[Place]:
    return Json(Place("nowhere", 0.0), status=404)


def _make(body: Json[Place]) -> String:
    return "made"


def test_additions_merged_as_written() raises:
    var app = App()
    app.get["/places/{id}"](_find)
    app.get["/raw"](raw)
    var ops = Dict[String, String]()
    ops[
        "GET /places/{id}"
    ] = '{"summary":"Find","responses":{"404":{"description":"No place"}}}'
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
        + '"404":{"description":"No place"}},"summary":"Find"}},'
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
        '{"parameters":[]}',
        "openapi: operations[POST /places]: parameters is derived",
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


def test_same_path_two_methods_one_path_item() raises:
    var app = App()
    app.get["/users/{id}"](_a)
    app.delete["/users/{id}"](_a)
    var doc = app.openapi(title="T", version="1")
    assert_true(doc.find('"/users/{id}":{"get":') >= 0)
    assert_true(doc.find('}},"delete":') >= 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
