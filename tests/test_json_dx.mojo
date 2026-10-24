# The JSON examples of docs/reference/bodies.md and responses.md (M3-009;
# `status=`, M3-029; `JsonWriter.field`, M3-075; `JsonFields`, M3-083;
# derived values inside hand-written codecs, M3-088), compiled and run as written
# there against production `muntin`. The successful JSON bodies go through
# `TestClient.post(target, body, headers=headers^)` with the `Content-Type`
# set, as the reference shows (M3-011), one of them also compared with
# `App.handle(Request(...))`; `TestClient.post` without the field is 415. The
# rejected bodies go through `App.handle(Request(..., headers^))`. The
# result-only route goes through `TestClient`.

from std.collections import Optional
from std.testing import assert_equal, TestSuite

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


# fmt: off
# example: bodies-json
from muntin import App, FromJson, Json, JsonValue, JsonWriter, ToJson


@fieldwise_init
struct CreateUser(FromJson):
    var name: String
    var age: Int
    var nickname: Optional[String]

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:   # raise -> 400, handler not called
        var nick = Optional[String]()
        var n = value.get("nickname")                  # None when absent
        if n and not n.value().is_null():
            nick = n.value().string()
        return Self(value["name"].string(), value["age"].int(), nick^)


@fieldwise_init
struct User(ToJson):
    var id: Int
    var name: String

    def write_json(self, mut out: JsonWriter) raises:  # raise -> fixed 500, not the handler's error
        out.begin_object()
        out.field("id", self.id)
        out.field("name", self.name)
        out.end_object()


def create_user(body: Json[CreateUser]) -> Json[User]:    # borrow and read body.value
    return Json(User(1, body.value.name))


def replace_user(id: Int, var body: Json[CreateUser]) -> Json[User]:
    var c = body^.take()                                  # own: the whole value, moved out
    return Json(User(id, c.name))
# example: end
# fmt: on


# example: responses-json
def register(var body: Json[CreateUser]) -> Json[User]:
    var c = body^.take()
    return Json(User(2, c.name), status=201)


# example: end


# fmt: off
# example: responses-json-media-type
def create() raises -> Response:
    var r = Json(User(7, "Ada"), status=201).to_response()
    r.headers.set("Content-Type", "application/problem+json")   # a set after the conversion wins
    return r^
# example: end
# fmt: on


# fmt: off
# example: responses-json-writer
@fieldwise_init
struct Place(Copyable, ToJson):
    var city: String
    var zip: Int

    def write_json(self, mut out: JsonWriter) raises:
        out.begin_object()
        out.field("city", self.city)
        out.field("zip", self.zip)
        out.end_object()


@fieldwise_init
struct Profile(ToJson):
    var id: Int
    var nickname: Optional[String]
    var tags: List[String]
    var home: Place
    var past: List[Place]

    def write_json(self, mut out: JsonWriter) raises:
        out.begin_object()
        out.field("id", self.id)              # Int, Float64, Bool or String
        out.field("nickname", self.nickname)  # an Optional: empty is null, not left out
        out.field("tags", self.tags)          # a List: an array
        out.field("home", self.home)          # a ToJson type
        out.field("past", self.past)          # a List (or Optional) of one
        out.end_object()


def profile(id: Int) -> Json[Profile]:
    return Json(Profile(id, None, ["a"], Place("Tokyo", 100), [Place("Osaka", 5)]))
# example: end
# fmt: on


# fmt: off
# example: bodies-json-derived
from muntin import App, Json, JsonFields


@fieldwise_init
struct NewNote(JsonFields):       # a JSON object, one member per field, named after it
    var text: String
    var tags: List[String]
    var due: Optional[Int]        # may be absent or null; every other member is required


@fieldwise_init
struct Note(JsonFields):
    var id: Int
    var text: String
    var tags: List[String]
    var due: Optional[Int]        # an empty Optional is written as null


def create_note(body: Json[NewNote]) -> Json[Note]:
    ref n = body.value
    return Json(Note(1, n.text, n.tags.copy(), n.due), status=201)


def import_notes(body: Json[List[NewNote]]) -> Json[List[Note]]:   # a top-level List
    var notes = List[Note]()
    for i in range(len(body.value)):
        ref n = body.value[i]
        notes.append(Note(i + 1, n.text, n.tags.copy(), n.due))
    return Json(notes^)
# example: end
# fmt: on


def make_notes_app() -> App:
    var app = App()
    # fmt: off
    # example: bodies-json-derived
    app.post["/notes"](create_note)
    app.post["/notes/import"](import_notes)
    # POST /notes  Content-Type: application/json  {"text":"hi","tags":["a"]}
    #   -> 201, Content-Type: application/json, {"id":1,"text":"hi","tags":["a"],"due":null}
    # POST /notes/import  [{"text":"a","tags":[]},{"text":"b","tags":[],"due":3}]
    #   -> 200, [{"id":1,"text":"a","tags":[],"due":null},{"id":2,"text":"b","tags":[],"due":3}]
    # {"tags":[]} -> 400 "Bad Request"; its Rejection: from_json: text: JSON member is missing
    # [{"text":"a","tags":[1]}] -> 400; its Rejection: from_json: [0].tags[0]: JSON value is not a string
    # example: end
    # fmt: on
    return app^


def test_derived_json_example() raises:
    var app = make_notes_app()
    var client = TestClient(app)
    var r = client.post(
        "/notes",
        '{"text":"hi","tags":["a"]}',
        headers=_content_type("application/json"),
    )
    assert_equal(r.status, 201)
    assert_equal(r.text(), '{"id":1,"text":"hi","tags":["a"],"due":null}')
    assert_equal(len(r.headers), 1)
    assert_equal(r.headers.get("content-type").value(), "application/json")
    r = client.post(
        "/notes/import",
        '[{"text":"a","tags":[]},{"text":"b","tags":[],"due":3}]',
        headers=_content_type("application/json"),
    )
    assert_equal(r.status, 200)
    assert_equal(
        r.text(),
        '[{"id":1,"text":"a","tags":[],"due":null},'
        + '{"id":2,"text":"b","tags":[],"due":3}]',
    )
    r = client.post(
        "/notes", '{"tags":[]}', headers=_content_type("application/json")
    )
    assert_equal(r.status, 400)
    assert_equal(r.text(), "Bad Request")
    assert_equal(
        String(r.rejection().value()), "from_json: text: JSON member is missing"
    )
    r = client.post(
        "/notes/import",
        '[{"text":"a","tags":[1]}]',
        headers=_content_type("application/json"),
    )
    assert_equal(r.status, 400)
    assert_equal(
        String(r.rejection().value()),
        "from_json: [0].tags[0]: JSON value is not a string",
    )
    # A null `Optional` member reads as empty, as an absent one does.
    r = client.post(
        "/notes",
        '{"text":"hi","tags":[],"due":null}',
        headers=_content_type("application/json"),
    )
    assert_equal(r.text(), '{"id":1,"text":"hi","tags":[],"due":null}')


def _post(
    app: App, target: String, body: String, *types: String
) raises -> Response:
    var headers = Headers()
    for t in types:
        headers.add("Content-Type", t)
    return app.handle(Request("POST", target, body, headers^))


def _content_type(t: String) raises -> Headers:
    var headers = Headers()
    headers.add("Content-Type", t)
    return headers^


def test_dx_json_examples() raises:
    var app = App()
    # fmt: off
    # example: bodies-json
    app.post["/users"](create_user)          # body only
    app.post["/users/{id}"](replace_user)    # route value, then body
    # POST /users  Content-Type: application/json  {"name":"Ada","age":36}
    #   -> 200, Content-Type: application/json, {"id":1,"name":"Ada"}
    # Content-Type missing, text/plain, two fields, or application/problem+json
    #   -> 415 "Unsupported Media Type" (before parsing and the handler)
    # a body over 1 MiB -> 413 "Content Too Large" (after the 415 check, before parsing)
    # application/json; charset=utf-8 -> accepted (parameters are not interpreted)
    # malformed JSON, a missing member, a wrong kind -> 400 "Bad Request"
    # example: end
    # fmt: on
    app.get["/create"](create)
    var client = TestClient(app)
    var headers = Headers()
    headers.add("Content-Type", "application/json")
    var r = client.post("/users", '{"name":"Ada","age":36}', headers=headers^)
    assert_equal(r.status, 200)
    assert_equal(r.text(), '{"id":1,"name":"Ada"}')
    assert_equal(len(r.headers), 1)
    assert_equal(r.headers.get("content-type").value(), "application/json")
    var direct = app.handle(
        Request(
            "POST",
            "/users",
            '{"name":"Ada","age":36}',
            _content_type("application/json"),
        )
    )
    assert_equal(r.status, direct.status)
    assert_equal(r.body, direct.body)
    assert_equal(len(r.headers), len(direct.headers))
    assert_equal(r.headers.name(0), direct.headers.name(0))
    assert_equal(r.headers.value(0), direct.headers.value(0))
    assert_equal(
        client.post(
            "/users/4",
            '{"name":"Bo","age":1,"nickname":null}',
            headers=_content_type("application/json"),
        ).text(),
        '{"id":4,"name":"Bo"}',
    )
    assert_equal(
        client.post(
            "/users",
            '{"name":"Ada","age":36}',
            headers=_content_type("application/json; charset=utf-8"),
        ).status,
        200,
    )
    # Content-Type missing, text/plain, two fields, application/problem+json.
    var ok = '{"name":"Ada","age":36}'
    for r415 in [
        _post(app, "/users", ok),
        _post(app, "/users", ok, "text/plain"),
        _post(app, "/users", ok, "application/json", "application/json"),
        _post(app, "/users", ok, "application/problem+json"),
        TestClient(app).post("/users", ok),
    ]:
        assert_equal(r415.status, 415)
        assert_equal(r415.text(), "Unsupported Media Type")
    # A body over 1 MiB.
    var big = ok + String(" ") * (1_048_576 - ok.byte_length() + 1)
    var r413 = _post(app, "/users", big, "application/json")
    assert_equal(r413.status, 413)
    assert_equal(r413.text(), "Content Too Large")
    # Malformed JSON, a missing member, a wrong kind.
    for bad in ['{"name":', '{"name":"Ada"}', '{"name":"Ada","age":"36"}']:
        var r400 = _post(app, "/users", bad, "application/json")
        assert_equal(r400.status, 400)
        assert_equal(r400.text(), "Bad Request")
    var c = TestClient(app).get("/create")
    assert_equal(c.status, 201)
    assert_equal(c.text(), '{"id":7,"name":"Ada"}')
    assert_equal(
        c.headers.get("content-type").value(), "application/problem+json"
    )


def test_json_result_status() raises:
    # example: responses-json
    var app = App()
    app.post["/accounts"](register)
    # POST /accounts  Content-Type: application/json  {"name":"Bo","age":1}
    #   -> 201, Content-Type: application/json, {"id":2,"name":"Bo"}
    # example: end
    var a = TestClient(app).post(
        "/accounts",
        '{"name":"Bo","age":1}',
        headers=_content_type("application/json"),
    )
    assert_equal(a.status, 201)
    assert_equal(a.text(), '{"id":2,"name":"Bo"}')
    assert_equal(len(a.headers), 1)
    assert_equal(a.headers.get("content-type").value(), "application/json")


def test_json_writer_members() raises:
    # fmt: off
    # example: responses-json-writer
    var app = App()
    app.get["/profiles/{id}"](profile)
    # GET /profiles/7  -> 200, Content-Type: application/json,
    #   {"id":7,"nickname":null,"tags":["a"],"home":{"city":"Tokyo","zip":100},
    #    "past":[{"city":"Osaka","zip":5}]}
    # example: end
    # fmt: on
    var r = TestClient(app).get("/profiles/7")
    assert_equal(r.status, 200)
    assert_equal(
        r.text(),
        '{"id":7,"nickname":null,"tags":["a"],'
        + '"home":{"city":"Tokyo","zip":100},'
        + '"past":[{"city":"Osaka","zip":5}]}',
    )
    assert_equal(len(r.headers), 1)
    assert_equal(r.headers.get("content-type").value(), "application/json")


# fmt: off
# example: responses-json-hand-written-derived
from muntin import App, FromJson, Json, JsonFields, JsonValue, JsonWriter, ToJson


@fieldwise_init
struct Stop(Copyable, JsonFields):
    var city: String
    var zip: Optional[Int]


@fieldwise_init
struct Trip(Copyable, FromJson, ToJson):     # one special member, the rest derived
    var start: Stop
    var stops: List[Stop]

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        if value["v"].int() != 2:                     # checked, not stored
            raise Error("unsupported version")
        return Self(value.read[Stop]("start"), value.read[List[Stop]]("stops"))

    def write_json(self, mut out: JsonWriter) raises:
        out.begin_object()
        out.field("v", 2)
        out.field("start", self.start)                # a JsonFields struct, as Json[Stop] writes it
        out.field("stops", self.stops)                # a List (or Optional) of one
        out.end_object()


def echo_trip(body: Json[Trip]) -> Json[Trip]:
    return Json(body.value.copy())
# example: end
# fmt: on


def test_hand_written_derived_example() raises:
    var app = App()
    # fmt: off
    # example: responses-json-hand-written-derived
    app.post["/trips"](echo_trip)
    # POST /trips  Content-Type: application/json  {"v":2,"start":{"city":"X"},"stops":[]}
    #   -> 200, {"v":2,"start":{"city":"X","zip":null},"stops":[]}
    # {"v":2,"start":{"city":1},"stops":[]} -> 400; its Rejection: from_json: start.city: JSON value is not a string
    # {"v":1,"start":{"city":"X"},"stops":[]} -> 400; its Rejection: from_json: unsupported version
    # example: end
    # fmt: on
    var client = TestClient(app)
    var r = client.post(
        "/trips",
        '{"v":2,"start":{"city":"X"},"stops":[]}',
        headers=_content_type("application/json"),
    )
    assert_equal(r.status, 200)
    assert_equal(r.text(), '{"v":2,"start":{"city":"X","zip":null},"stops":[]}')
    r = client.post(
        "/trips",
        '{"v":2,"start":{"city":1},"stops":[]}',
        headers=_content_type("application/json"),
    )
    assert_equal(r.status, 400)
    assert_equal(r.text(), "Bad Request")
    assert_equal(r.rejection().value().step, Rejection.FROM_JSON)
    assert_equal(
        r.rejection().value().message, "start.city: JSON value is not a string"
    )
    r = client.post(
        "/trips",
        '{"v":1,"start":{"city":"X"},"stops":[]}',
        headers=_content_type("application/json"),
    )
    assert_equal(r.status, 400)
    assert_equal(r.rejection().value().message, "unsupported version")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
