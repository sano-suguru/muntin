# Route-value records (M3-062): a `RouteValues` struct is one request slot
# carrying every route value of its route, one field per placeholder, built
# field by field without its `__init__`. Through `TestClient` and `App.handle`:
# docs/reference/route-values.md's example as written, path and query fields, an
# `Optional` absent and present, a generic record, fields of mixed sizes, a
# backquoted `{org-id}` field, each 400, the construction's ownership, an
# `__init__` that is never called, `Headers` or a body after a record, the
# bodyless and stateful forms, and one and two fields. Decision:
# docs/history/architecture-decisions.md, "Route-value records decision
# (M3-061)". Must-not-compile counterparts: tests/route_records_api_fail.
#
# The ownership oracle counts in environment variables: a route-value
# conversion receives only its text, so a counter cannot be passed to it,
# and Mojo 1.1.0 has no global variables. `SANITIZE=address
# ./scripts/test.sh tests/test_route_records.mojo` runs the same oracle
# with a heap-allocated `String` field built before a failing one.

from std.os import abort, getenv, setenv
from std.testing import assert_equal, TestSuite

from muntin import (
    App,
    FromBody,
    FromBytes,
    FromJson,
    FromRouteValue,
    Headers,
    Json,
    JsonValue,
    JsonWriter,
    Request,
    RouteValues,
    State,
    ToJson,
    WithHeaders,
)
from muntin.testing import TestClient


# docs/reference/route-values.md, "Route-value records": the text between the
# `# example:` lines is what the page shows (scripts/check_doc_examples.py).


# fmt: off
# example: route-values-records
from muntin import App, FromJson, Json, JsonValue, JsonWriter, RouteValues, State, ToJson


@fieldwise_init
struct TaskAt(RouteValues):
    var org_id: Int
    var project_id: Int
    var task_id: Int


@fieldwise_init
struct Task(Copyable, ToJson):
    var org_id: Int
    var project_id: Int
    var task_id: Int
    var title: String

    def write_json(self, mut out: JsonWriter) raises:
        out.begin_object()
        out.name("org_id")
        out.int(self.org_id)
        out.name("project_id")
        out.int(self.project_id)
        out.name("task_id")
        out.int(self.task_id)
        out.name("title")
        out.string(self.title)
        out.end_object()


@fieldwise_init
struct TaskEdit(FromJson):
    var title: String

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        return Self(value["title"].string())


@fieldwise_init
struct Db(Movable):
    var title: String


def get_task(at: TaskAt) -> Json[Task]:
    return Json(Task(at.org_id, at.project_id, at.task_id, "first"))


def update_task(
    db: State[Db], at: TaskAt, body: Json[TaskEdit]
) raises -> Json[Task]:
    if at.task_id == 0:
        raise Error("no task 0")
    return Json(
        Task(at.org_id, at.project_id, at.task_id, body.value.title + " in " + db[].title)
    )


comptime TASK = "/organizations/{org_id}/projects/{project_id}/tasks/{task_id}"


def make_dx_app() -> App:
    var app = App()
    app.get[TASK](get_task)
    app.patch[TASK](update_task, State(Db("db")))
    return app^
# GET /organizations/1/projects/2/tasks/3 -> 200 {"org_id":1,"project_id":2,"task_id":3,"title":"first"}
# PATCH /organizations/4/projects/5/tasks/6  Content-Type: application/json  {"title":"renamed"}
#   -> 200 {"org_id":4,"project_id":5,"task_id":6,"title":"renamed in db"}
# PATCH /organizations/4/projects/x/tasks/6  (no Content-Type) -> 400 "Bad Request"  (before the body's 415)
# PATCH /organizations/4/projects/5/tasks/6  (no Content-Type) -> 415 "Unsupported Media Type"
# example: end
# fmt: on


def _json_headers() raises -> Headers:
    var h = Headers()
    h.add("Content-Type", "application/json")
    return h^


def test_dx_example() raises:
    var app = make_dx_app()
    var client = TestClient(app)
    var r = client.get("/organizations/1/projects/2/tasks/3")
    assert_equal(r.status, 200)
    assert_equal(
        r.text(), '{"org_id":1,"project_id":2,"task_id":3,"title":"first"}'
    )
    r = client.patch(
        "/organizations/4/projects/5/tasks/6",
        '{"title":"renamed"}',
        headers=_json_headers(),
    )
    assert_equal(r.status, 200)
    assert_equal(
        r.text(),
        '{"org_id":4,"project_id":5,"task_id":6,"title":"renamed in db"}',
    )
    # A field's 400 comes before the body's 415.
    r = client.patch("/organizations/4/projects/x/tasks/6", "not json")
    assert_equal(r.status, 400)
    r = client.patch("/organizations/4/projects/5/tasks/6", "not json")
    assert_equal(r.status, 415)
    # A handler error is the fixed 500, as for any typed handler.
    r = client.patch(
        "/organizations/4/projects/5/tasks/0",
        '{"title":"x"}',
        headers=_json_headers(),
    )
    assert_equal(r.status, 500)
    # `App.handle` with an owned request answers alike.
    r = app.handle(
        Request(
            "PATCH",
            "/organizations/7/projects/8/tasks/9",
            '{"title":"t"}',
            _json_headers(),
        )
    )
    assert_equal(r.status, 200)
    assert_equal(
        r.text(), '{"org_id":7,"project_id":8,"task_id":9,"title":"t in db"}'
    )


# Path and query fields, `Optional`s, application types.


@fieldwise_init
struct Slug(FromRouteValue):
    var text: String

    @staticmethod
    def from_route_value(value: String) raises -> Self:
        if value == "bad":
            raise Error("bad slug")
        return Self(value)


@fieldwise_init
struct Listing(RouteValues):
    var org: String
    var project: Slug
    var q: String
    var limit: Optional[Int]
    var sort: Optional[String]


def list_tasks(at: Listing) -> String:
    return String(
        "org=",
        at.org,
        " project=",
        at.project.text,
        " q=",
        at.q,
        " limit=",
        at.limit.or_else(-1),
        " sort=",
        at.sort.or_else("none"),
    )


def _expect(app: App, target: String, status: Int, body: String) raises:
    var r = TestClient(app).get(target)
    assert_equal(r.status, status, target)
    assert_equal(r.text(), body, target)


def test_path_and_query_fields() raises:
    var app = App()
    app.get["/o/{org}/p/{project}?{q}&{limit}&{sort}"](list_tasks)
    _expect(
        app,
        "/o/acme/p/web?q=a+b&limit=5&sort=new",
        200,
        "org=acme project=web q=a b limit=5 sort=new",
    )
    # Optional fields absent, empty, and in another order in the request.
    _expect(
        app,
        "/o/acme/p/web?q=x",
        200,
        "org=acme project=web q=x limit=-1 sort=none",
    )
    _expect(
        app,
        "/o/acme/p/web?sort=&limit=&q=x",
        200,
        "org=acme project=web q=x limit=-1 sort=none",
    )
    _expect(
        app,
        "/o/a%2Fb/p/web?limit=0&q=%41",
        200,
        "org=a/b project=web q=A limit=0 sort=none",
    )
    # Each 400: a raising application type, a missing or duplicated
    # required query value, an invalid optional `Int`, a bad escape.
    _expect(app, "/o/acme/p/bad?q=x", 400, "Bad Request")
    _expect(app, "/o/acme/p/web", 400, "Bad Request")
    _expect(app, "/o/acme/p/web?q=", 400, "Bad Request")
    _expect(app, "/o/acme/p/web?q=a&q=b", 400, "Bad Request")
    _expect(app, "/o/acme/p/web?q=x&limit=ten", 400, "Bad Request")
    _expect(app, "/o/%zz/p/web?q=x", 400, "Bad Request")
    _expect(app, "/o/acme/p/web/extra?q=x", 404, "Not Found")


def test_int_fields_reject_non_integers() raises:
    var app = make_dx_app()
    _expect(app, "/organizations/1/projects/2/tasks/x", 400, "Bad Request")
    _expect(app, "/organizations/x/projects/2/tasks/3", 400, "Bad Request")
    _expect(app, "/organizations/1/projects/2/tasks/", 404, "Not Found")


# A generic record, fields of mixed sizes, a backquoted name.


@fieldwise_init
struct Pair[T: Movable & Deinitable](RouteValues):
    var first: Self.T
    var second: Int


def pair_of_text(at: Pair[String]) -> String:
    return String(at.first, "+", at.second)


def pair_of_int(at: Pair[Int]) -> String:
    return String(at.first + at.second)


def test_generic_record() raises:
    var app = App()
    app.get["/t/{first}/{second}"](pair_of_text)
    app.get["/i?{first}&{second}"](pair_of_int)
    _expect(app, "/t/ab/3", 200, "ab+3")
    _expect(app, "/i?second=3&first=4", 200, "7")
    _expect(app, "/i?first=x&second=3", 400, "Bad Request")


@fieldwise_init
struct Flag(FromRouteValue):
    var on: UInt8

    @staticmethod
    def from_route_value(value: String) raises -> Self:
        if value == "on":
            return Self(1)
        if value == "off":
            return Self(0)
        raise Error("not a flag")


@fieldwise_init
struct Mixed(RouteValues):
    var flag: Flag
    var count: Optional[Int]
    var tiny: Flag
    var name: String


def show_mixed(at: Mixed) -> String:
    return String(
        Int(at.flag.on),
        " ",
        at.count.or_else(-1),
        " ",
        Int(at.tiny.on),
        " ",
        at.name,
    )


def test_fields_of_mixed_sizes() raises:
    # A one-byte field before an `Optional[Int]`, another before a `String`:
    # each is written at its own offset, padding left to the compiler.
    var app = App()
    app.get["/m/{flag}?{count}&{tiny}&{name}"](show_mixed)
    _expect(
        app,
        "/m/on?count=42&tiny=off&name=a-name-longer-than-inline-storage",
        200,
        "1 42 0 a-name-longer-than-inline-storage",
    )
    _expect(app, "/m/off?tiny=on&name=n", 200, "0 -1 1 n")
    _expect(app, "/m/maybe?tiny=on&name=n", 400, "Bad Request")
    _expect(app, "/m/on?tiny=maybe&name=n", 400, "Bad Request")


@fieldwise_init
struct Dashed(RouteValues):
    var `org-id`: Int
    var `team.name`: String


def show_dashed(at: Dashed) -> String:
    return String(at.`org-id`, " ", at.`team.name`)


def test_backquoted_field_names() raises:
    var app = App()
    app.get["/orgs/{org-id}?{team.name}"](show_dashed)
    _expect(app, "/orgs/5?team.name=core", 200, "5 core")


# One and two fields, `Headers` and bodies after a record, bodyless and
# stateful forms.


@fieldwise_init
struct One(RouteValues):
    var id: Int


@fieldwise_init
struct Two(RouteValues):
    var user: String
    var post: Int


@fieldwise_init
struct Note(FromBody):
    var text: String

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


@fieldwise_init
struct Blob(FromBytes):
    comptime max_bytes = 4
    var size: Int

    @staticmethod
    def from_bytes(bytes: List[UInt8]) raises -> Self:
        return Self(len(bytes))


def one(at: One) -> String:
    return String("one ", at.id)


def two(at: Two) -> String:
    return String("two ", at.user, " ", at.post)


def one_with_headers(at: One, headers: Headers) -> String:
    return String("one ", at.id, " ", headers.get("x-tag").or_else("-"))


def two_with_headers(at: Two, headers: Headers) -> String:
    return String(
        "two ", at.user, " ", at.post, " ", headers.get("x-tag").or_else("-")
    )


def two_with_note(at: Two, note: Note) -> String:
    return String("two ", at.user, " ", at.post, " ", note.text)


def one_with_json(at: One, body: Json[TaskEdit]) -> String:
    return String("one ", at.id, " ", body.value.title)


def one_with_blob(at: One, blob: Blob) -> String:
    return String("one ", at.id, " ", blob.size, " bytes")


def one_with_carried_note(at: One, input: WithHeaders[Note]) -> String:
    return String(
        "one ",
        at.id,
        " ",
        input.body.text,
        " ",
        input.headers.get("x-tag").or_else("-"),
    )


def stateful_two(db: State[Db], at: Two) -> String:
    return String(db[].title, " ", at.user, " ", at.post)


def stateful_one_headers(db: State[Db], at: One, headers: Headers) -> String:
    return String(db[].title, " ", at.id, " ", len(headers))


def stateful_two_note(db: State[Db], at: Two, note: Note) -> String:
    return String(db[].title, " ", at.user, " ", at.post, " ", note.text)


def _tagged() raises -> Headers:
    var h = Headers()
    h.add("X-Tag", "t1")
    return h^


def test_one_and_two_fields_on_every_method() raises:
    var app = App()
    app.get["/one/{id}"](one)
    app.delete["/one/{id}"](one)
    app.post["/one/{id}"](one)
    app.put["/one/{id}"](one)
    app.patch["/two/{user}?{post}"](two)
    var client = TestClient(app)
    assert_equal(client.get("/one/1").text(), "one 1")
    assert_equal(client.delete("/one/2").text(), "one 2")
    assert_equal(client.post("/one/3", "ignored").text(), "one 3")
    assert_equal(client.put("/one/4", "").text(), "one 4")
    assert_equal(client.patch("/two/ada?post=5", "").text(), "two ada 5")
    assert_equal(client.patch("/two/ada", "").status, 400)
    # A `GET` record route answers `HEAD` as `GET`.
    assert_equal(client.head("/one/6").text(), "one 6")


def test_headers_and_bodies_after_a_record() raises:
    var app = App()
    app.get["/h/{id}"](one_with_headers)
    app.post["/bodyless/{id}"](one_with_headers)
    app.get["/h2/{user}/{post}"](two_with_headers)
    app.post["/n/{user}/{post}"](two_with_note)
    app.put["/j/{id}"](one_with_json)
    app.patch["/b/{id}"](one_with_blob)
    app.post["/c/{id}"](one_with_carried_note)
    var client = TestClient(app)
    assert_equal(client.get("/h/1", headers=_tagged()).text(), "one 1 t1")
    assert_equal(client.get("/h/1").text(), "one 1 -")
    assert_equal(client.get("/h/x", headers=_tagged()).status, 400)
    # The header fields start after the record's two values.
    assert_equal(
        client.get("/h2/ada/7", headers=_tagged()).text(), "two ada 7 t1"
    )
    assert_equal(
        client.post("/bodyless/2", "", headers=_tagged()).text(), "one 2 t1"
    )
    assert_equal(client.post("/n/ada/3", "hello").text(), "two ada 3 hello")
    assert_equal(client.post("/n/ada/x", "hello").status, 400)
    var r = client.put("/j/4", '{"title":"t"}', headers=_json_headers())
    assert_equal(r.status, 200)
    assert_equal(r.text(), "one 4 t")
    assert_equal(client.put("/j/4", '{"title":"t"}').status, 415)
    assert_equal(
        client.put("/j/x", '{"title":"t"}', headers=_json_headers()).status, 400
    )
    assert_equal(client.patch("/b/5", "abcd").text(), "one 5 4 bytes")
    assert_equal(client.patch("/b/5", "abcde").status, 413)
    assert_equal(
        client.post("/c/6", "note", headers=_tagged()).text(), "one 6 note t1"
    )


def task_with_headers(at: TaskAt, headers: Headers) -> String:
    return String(
        at.org_id,
        "/",
        at.project_id,
        "/",
        at.task_id,
        " ",
        headers.get("x-tag").or_else("-"),
    )


def task_with_carried_json(
    at: TaskAt, input: WithHeaders[Json[TaskEdit]]
) -> String:
    return String(
        at.org_id,
        "/",
        at.project_id,
        "/",
        at.task_id,
        " ",
        input.body.value.title,
        " ",
        input.headers.get("x-tag").or_else("-"),
    )


def task_with_note(at: TaskAt, note: Note) -> String:
    return String(
        at.org_id, "/", at.project_id, "/", at.task_id, " ", note.text
    )


def _tagged_json() raises -> Headers:
    var h = _json_headers()
    h.add("X-Tag", "t2")
    return h^


def test_three_fields_with_headers_bodies_and_every_method() raises:
    # The header fields and the JSON verdict start after the record's three
    # values (`_width`).
    var app = App()
    app.get["/h3/{org_id}/{project_id}/{task_id}"](task_with_headers)
    app.post["/c3/{org_id}/{project_id}/{task_id}"](task_with_carried_json)
    app.put["/n3/{org_id}/{project_id}/{task_id}"](task_with_note)
    app.delete["/d3/{org_id}/{project_id}/{task_id}"](task_with_headers)
    app.patch["/p3/{org_id}/{project_id}?{task_id}"](task_with_note)
    var client = TestClient(app)
    assert_equal(client.get("/h3/1/2/3", headers=_tagged()).text(), "1/2/3 t1")
    assert_equal(client.get("/h3/1/2/x", headers=_tagged()).status, 400)
    var r = client.post("/c3/4/5/6", '{"title":"t"}', headers=_tagged_json())
    assert_equal(r.status, 200)
    assert_equal(r.text(), "4/5/6 t t2")
    assert_equal(
        client.post("/c3/4/5/6", '{"title":"t"}', headers=_tagged()).status, 415
    )
    assert_equal(
        client.post(
            "/c3/4/x/6", '{"title":"t"}', headers=_tagged_json()
        ).status,
        400,
    )
    assert_equal(client.put("/n3/7/8/9", "note").text(), "7/8/9 note")
    assert_equal(client.delete("/d3/1/1/1").text(), "1/1/1 -")
    assert_equal(client.patch("/p3/1/2?task_id=3", "n").text(), "1/2/3 n")
    assert_equal(client.patch("/p3/1/2", "n").status, 400)


struct Wide(RouteValues):
    """Ten path fields and twenty query fields, five of them optional."""

    var p0: Int
    var p1: String
    var p2: Int
    var p3: Int
    var p4: Int
    var p5: Int
    var p6: Int
    var p7: Int
    var p8: Int
    var p9: Counted
    var q0: Int
    var q1: Int
    var q2: Int
    var q3: Int
    var q4: Int
    var q5: Int
    var q6: Int
    var q7: Int
    var q8: Int
    var q9: Int
    var q10: Int
    var q11: Int
    var q12: Int
    var q13: Int
    var q14: Counted
    var q15: Optional[Int]
    var q16: Optional[String]
    var q17: Optional[Int]
    var q18: Optional[String]
    var q19: Optional[Int]


def _opt(value: Optional[Int]) -> String:
    return String(value.value()) if value else "none"


def _opt(value: Optional[String]) -> String:
    return value.value() if value else "none"


def wide(at: Wide) -> String:
    # Every field, in field order, so any two fields exchanged change the
    # text.
    var parts: List[String] = [
        String(at.p0),
        at.p1,
        String(at.p2),
        String(at.p3),
        String(at.p4),
        String(at.p5),
        String(at.p6),
        String(at.p7),
        String(at.p8),
        at.p9.text,
        String(at.q0),
        String(at.q1),
        String(at.q2),
        String(at.q3),
        String(at.q4),
        String(at.q5),
        String(at.q6),
        String(at.q7),
        String(at.q8),
        String(at.q9),
        String(at.q10),
        String(at.q11),
        String(at.q12),
        String(at.q13),
        at.q14.text,
        _opt(at.q15),
        _opt(at.q16),
        _opt(at.q17),
        _opt(at.q18),
        _opt(at.q19),
    ]
    return ",".join(parts)


comptime WIDE = (
    "/w/{p0}/{p1}/{p2}/{p3}/{p4}/{p5}/{p6}/{p7}/{p8}/{p9}"
    "?{q0}&{q1}&{q2}&{q3}&{q4}&{q5}&{q6}&{q7}&{q8}&{q9}&{q10}&{q11}&{q12}"
    "&{q13}&{q14}&{q15}&{q16}&{q17}&{q18}&{q19}"
)


def _wide_query(q14: String, optionals: String) -> String:
    # q0 to q13 are 100 to 113, each value distinct from every path value.
    var query = String("?unrelated=1")
    for i in range(14):
        query += String("&q", i, "=", 100 + i)
    return query + "&q14=" + q14 + optionals + "&unrelated=2"


comptime WIDE_PATH = "/w/1/name/3/4/5/6/7/8/9/c"
comptime WIDE_VALUES = (
    "1,name,3,4,5,6,7,8,9,c,100,101,102,103,104,105,106,107,108,109,110,111,"
    "112,113,k,"
)


def test_thirty_fields_path_query_and_optional() raises:
    # Each field binds its own placeholder: the handler answers every field
    # in field order, with distinct values, so any two exchanged change the
    # answer. The query has more than `_LINEAR_QUERY_KEYS` keys, so its
    # values are found through the route's key index.
    var app = App()
    app.get[WIDE](wide)
    var client = TestClient(app)
    _reset()
    var r = client.get(
        WIDE_PATH + _wide_query("k", "&q15=15&q16=s16&q17=17&q18=s18&q19=19")
    )
    assert_equal(r.status, 200)
    assert_equal(r.text(), WIDE_VALUES + "15,s16,17,s18,19")
    _expect_counts("wide", 2, 2, 2, 0, 0, 0)
    # Each optional field absent, empty, or a pair without `=`.
    r = client.get(WIDE_PATH + _wide_query("k", "&q16=&q17"))
    assert_equal(r.status, 200)
    assert_equal(r.text(), WIDE_VALUES + "none,none,none,none,none")
    # Some optional fields present, the others absent.
    r = client.get(WIDE_PATH + _wide_query("k", "&q16=x&q18=y"))
    assert_equal(r.text(), WIDE_VALUES + "none,x,none,y,none")
    # One of the route's keys twice is 400; an unrelated key twice is not.
    assert_equal(client.get(WIDE_PATH + _wide_query("k", "&q3=1")).status, 400)
    # A missing required query value is 400 before any field converts.
    _reset()
    r = client.get(WIDE_PATH + "?q0=1")
    assert_equal(r.status, 400)
    _expect_counts("wide missing", 0, 0, 0, 0, 0, 0)
    # A failing path field: nothing before it was a counted field.
    _reset()
    r = client.get("/w/1/name/3/4/5/6/7/8/9/fail" + _wide_query("k", ""))
    assert_equal(r.status, 400)
    _expect_counts("wide fail", 1, 0, 0, 0, 0, 0)
    # A failing query field after a built one: the built one is destroyed.
    _reset()
    r = client.get(WIDE_PATH + _wide_query("fail", ""))
    assert_equal(r.status, 400)
    _expect_counts("wide late fail", 2, 1, 1, 0, 0, 0)


def test_stateful_forms() raises:
    var app = App()
    var db = State(Db("db"))
    app.get["/s/{user}/{post}"](stateful_two, db)
    app.delete["/s/{id}"](stateful_one_headers, db)
    app.put["/s/{user}?{post}"](stateful_two_note, db)
    var client = TestClient(app)
    assert_equal(client.get("/s/ada/1").text(), "db ada 1")
    assert_equal(client.delete("/s/2", headers=_tagged()).text(), "db 2 1")
    assert_equal(client.put("/s/ada?post=3", "hi").text(), "db ada 3 hi")
    assert_equal(client.put("/s/ada?post=x", "hi").status, 400)


# A record's own `__init__` is never called, so neither is its check.


struct Range(RouteValues):
    var start_id: Int
    var end_id: Int

    def __init__(out self, start_id: Int, end_id: Int):
        if start_id > end_id:
            abort("Range.__init__ ran")
        self.start_id = start_id
        self.end_id = end_id


def show_range(r: Range) -> String:
    return String(r.start_id, "..", r.end_id)


def test_init_is_never_called() raises:
    # `/r/5/1` would abort the process in `Range.__init__`; the record is
    # built without it, so the relation across fields is the handler's.
    var app = App()
    app.get["/r/{start_id}/{end_id}"](show_range)
    _expect(app, "/r/5/1", 200, "5..1")
    _expect(app, "/r/1/x", 400, "Bad Request")


# The construction's ownership oracle.


def _count(name: String) -> Int:
    try:
        return Int(getenv(name, "0"))
    except:
        return -1


def _bump(name: String):
    _ = setenv(name, String(_count(name) + 1))


def _append(name: String, text: String):
    var now = getenv(name, "")
    _ = setenv(name, now + text if now == "" else now + "," + text)


def _reset():
    _ = setenv("MUNTIN_RR_ORDER", "")
    for name in [
        "MUNTIN_RR_TRIED",
        "MUNTIN_RR_BUILT",
        "MUNTIN_RR_DROPPED",
        "MUNTIN_RR_RECORDS_DROPPED",
        "MUNTIN_RR_BODIES",
        "MUNTIN_RR_CALLS",
    ]:
        _ = setenv(name, "0")


struct Counted(FromRouteValue):
    """A route value counting its conversions (tried and built) and its
    destructions; the text `fail` makes the conversion raise."""

    var text: String

    def __init__(out self, text: String):
        self.text = text

    @staticmethod
    def from_route_value(value: String) raises -> Self:
        _bump("MUNTIN_RR_TRIED")
        if value == "fail":
            raise Error("fail")
        _bump("MUNTIN_RR_BUILT")
        return Self(value)

    def __deinit__(deinit self):
        _bump("MUNTIN_RR_DROPPED")
        _append("MUNTIN_RR_ORDER", self.text)


struct Three(RouteValues):
    var a: Counted
    var b: Counted
    var c: Counted

    def __init__(out self):
        abort("Three.__init__ ran")

    def __deinit__(deinit self):
        _bump("MUNTIN_RR_RECORDS_DROPPED")


struct HeapThenCounted(RouteValues):
    var name: String
    var tag: Counted
    var after: Counted

    def __init__(out self):
        abort("HeapThenCounted.__init__ ran")

    def __deinit__(deinit self):
        _bump("MUNTIN_RR_RECORDS_DROPPED")


@fieldwise_init
struct CountedBody(FromBody):
    """A body counting its conversions; the body `fail` makes the
    conversion raise."""

    var text: String

    @staticmethod
    def from_body(body: String) raises -> Self:
        _bump("MUNTIN_RR_BODIES")
        if body == "fail":
            raise Error("fail")
        return Self(body)


def three(at: Three, body: CountedBody) -> String:
    _bump("MUNTIN_RR_CALLS")
    return String(at.a.text, at.b.text, at.c.text, " ", body.text)


def three_raising(at: Three, body: CountedBody) raises -> String:
    _bump("MUNTIN_RR_CALLS")
    raise Error("handler failed")


def heap_then_counted(at: HeapThenCounted) -> String:
    _bump("MUNTIN_RR_CALLS")
    return String(at.name, " ", at.tag.text, " ", at.after.text)


def _expect_counts(
    target: String,
    tried: Int,
    built: Int,
    dropped: Int,
    records: Int,
    bodies: Int,
    calls: Int,
) raises:
    assert_equal(_count("MUNTIN_RR_TRIED"), tried, target + " tried")
    assert_equal(_count("MUNTIN_RR_BUILT"), built, target + " built")
    assert_equal(_count("MUNTIN_RR_DROPPED"), dropped, target + " dropped")
    assert_equal(
        _count("MUNTIN_RR_RECORDS_DROPPED"), records, target + " records"
    )
    assert_equal(_count("MUNTIN_RR_BODIES"), bodies, target + " bodies")
    assert_equal(_count("MUNTIN_RR_CALLS"), calls, target + " calls")


def test_ownership_on_failure_at_each_field_and_on_success() raises:
    var app = App()
    app.post["/three/{a}/{b}/{c}"](three)
    app.post["/raise/{a}/{b}/{c}"](three_raising)
    var client = TestClient(app)
    # A failure at field k: fields 0 to k-1 were built and are each
    # destroyed once, no later field or the body is converted, the record's
    # destructor never runs, and the handler is not called.
    var targets: List[String] = [
        "/three/fail/y/z",
        "/three/x/fail/z",
        "/three/x/y/fail",
    ]
    var orders: List[String] = ["", "x", "x,y"]
    for k in range(3):
        _reset()
        var r = client.post(targets[k], "body")
        assert_equal(r.status, 400, targets[k])
        _expect_counts(targets[k], k + 1, k, k, 0, 0, 0)
        # The built fields are destroyed in field order, as Mojo destroys
        # a whole record's fields (the success case below).
        assert_equal(getenv("MUNTIN_RR_ORDER", ""), orders[k], targets[k])
    # Success: each field built once and destroyed once, with the record,
    # whose destructor runs once.
    _reset()
    var r = client.post("/three/x/y/z", "body")
    assert_equal(r.status, 200)
    assert_equal(r.text(), "xyz body")
    _expect_counts("/three/x/y/z", 3, 3, 3, 1, 1, 1)
    assert_equal(getenv("MUNTIN_RR_ORDER", ""), "x,y,z")
    # A body failing after a completed record: the record is destroyed
    # once, with each field once, and the handler is not called.
    _reset()
    r = client.post("/three/x/y/z", "fail")
    assert_equal(r.status, 400)
    _expect_counts("body fail", 3, 3, 3, 1, 1, 0)
    # A handler raising after it received the record: 500, and the record
    # and each field are destroyed once.
    _reset()
    r = client.post("/raise/x/y/z", "body")
    assert_equal(r.status, 500)
    _expect_counts("handler raise", 3, 3, 3, 1, 1, 1)


def test_heap_field_before_a_failing_one_is_destroyed() raises:
    # Under AddressSanitizer a leaked or doubly freed `String` buffer fails
    # the run; here the counts show each built field destroyed once.
    var app = App()
    app.get["/heap/{name}/{tag}/{after}"](heap_then_counted)
    var client = TestClient(app)
    _reset()
    var long_name = "a-name-much-longer-than-any-inline-string-storage"
    var r = client.get("/heap/" + long_name + "/fail/z")
    assert_equal(r.status, 400)
    _expect_counts("heap fail", 1, 0, 0, 0, 0, 0)
    _reset()
    r = client.get("/heap/" + long_name + "/t/fail")
    assert_equal(r.status, 400)
    _expect_counts("heap fail after", 2, 1, 1, 0, 0, 0)
    _reset()
    r = client.get("/heap/" + long_name + "/t/u")
    assert_equal(r.status, 200)
    assert_equal(r.text(), long_name + " t u")
    _expect_counts("heap ok", 2, 2, 2, 1, 0, 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
