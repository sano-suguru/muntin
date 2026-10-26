# docs/reference/openapi.md's example, with the answers its comments state.
# The text between `# example: openapi` and `# example: end` is what the
# page shows (scripts/check_doc_examples.py compares them); `# fmt: off`
# keeps its layout. The test sends its requests to the `App` that
# `make_app` returns. The type the page takes from another page comes
# first.
# Build flags (scripts/build_one.sh): -D MUNTIN_OPENAPI

from std.testing import assert_equal, TestSuite

from muntin import Response, ToErrorResponse
from muntin.testing import TestClient


# errors.md's `ToErrorResponse` type, for a note.


@fieldwise_init
struct NotFound(Movable, ToErrorResponse):
    var id: Int

    def to_error_response(var self) -> Response:
        return Response.text("no note " + String(self.id), status=404)


# fmt: off
# example: openapi
from std.collections import Dict

from muntin import App, Json, JsonFields, Response, State


@fieldwise_init
struct Note(Copyable, JsonFields):
    var id: Int
    var text: String


@fieldwise_init
struct NewNote(Copyable, JsonFields):
    var text: String


@fieldwise_init
struct ApiDocument(Movable):
    var json: String


def get_note(id: Int) raises NotFound -> Json[Note]:
    if id != 1:
        raise NotFound(id)
    return Json(Note(1, "first"))


def create_note(var body: Json[NewNote]) -> Json[Note]:
    var new = body^.take()
    return Json(Note(2, new.text), status=201)


def get_document(doc: State[ApiDocument]) raises -> Response:
    var response = Response.text(doc[].json)
    response.headers.set("Content-Type", "application/json")
    return response^


def make_app() raises -> App:
    var app = App()
    app.get["/notes/{id}"](get_note)
    app.post["/notes"](create_note)
    var operations = Dict[String, String]()   # what the types cannot say
    operations["GET /notes/{id}"] = '{"summary":"One note","responses":{"404":{"description":"No such note"}}}'
    var doc = app.openapi(title="Notes", version="1.0.0", operations=operations^)
    app.get["/openapi.json"](get_document, State(ApiDocument(doc^)))
    return app^
# Built with -D MUNTIN_OPENAPI; without it, app.openapi does not compile.
# GET /openapi.json -> 200, Content-Type: application/json, the document of
#   the two routes registered before it:
#   {"openapi":"3.1.0","info":{"title":"Notes","version":"1.0.0"},"paths":{
#    "/notes/{id}":{"get":{"parameters":[{"name":"id","in":"path",...}],
#      "responses":{"2XX":{...Note...},"404":{"description":"No such note"}},
#      "summary":"One note"}},
#    "/notes":{"post":{"parameters":[],"requestBody":{"required":true,...NewNote...},
#      "responses":{"2XX":{...Note...}}}}}}
# GET /notes/1 -> 200 {"id":1,"text":"first"};  GET /notes/2 -> 404 "no note 2"
# example: end
# fmt: on


def test_openapi() raises:
    var app = make_app()
    var client = TestClient(app)
    var r = client.get("/openapi.json")
    assert_equal(r.status, 200)
    assert_equal(r.headers.get("content-type").or_else(""), "application/json")
    var int64 = (
        '{"type":"integer","format":"int64","minimum":-9223372036854775808,'
        + '"maximum":9223372036854775807}'
    )
    var note = (
        '{"description":"The handler\'s JSON value","content":'
        + '{"application/json":{"schema":{"type":"object","properties":'
        + '{"id":'
        + int64
        + ',"text":{"type":"string"}},"required":["id","text"],'
        + '"additionalProperties":false}}}}'
    )
    assert_equal(
        r.text(),
        '{"openapi":"3.1.0","info":{"title":"Notes","version":"1.0.0"},'
        + '"paths":{"/notes/{id}":{"get":{"parameters":[{"name":"id",'
        + '"in":"path","required":true,"schema":'
        + int64
        + '}],"responses":{"2XX":'
        + note
        + ',"404":{"description":"No such note"}},"summary":"One note"}},'
        + '"/notes":{"post":{"parameters":[],"requestBody":{"required":true,'
        + '"content":{"application/json":{"schema":{"type":"object",'
        + '"properties":{"text":{"type":"string"}},"required":["text"]}}}},'
        + '"responses":{"2XX":'
        + note
        + "}}}}}",
    )
    r = client.get("/notes/1")
    assert_equal(r.status, 200)
    assert_equal(r.text(), '{"id":1,"text":"first"}')
    r = client.get("/notes/2")
    assert_equal(r.status, 404)
    assert_equal(r.text(), "no note 2")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
