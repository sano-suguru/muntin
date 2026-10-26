# OpenAPI

`app.openapi(title=, version=, document="", operations={}) raises -> String` returns the [OpenAPI 3.1](https://spec.openapis.org/oas/v3.1.0) document of the `App`'s routes as JSON text: one operation per route, written from the handler's types ([M3-091](../history/decisions/m3-091-openapi-output-decision.md)). What the types cannot say, the application adds as JSON objects. The document holds the routes registered before the call, so the application builds it once its routes are registered and serves it like any other start-up value.

<!-- example: tests/test_openapi_examples.mojo#openapi -->
```mojo
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
```

Run by `tests/test_openapi_examples.mojo` (`test_openapi`), which checks the whole document and the two answers. That module defines `NotFound`, the `ToErrorResponse` type of [errors](errors.md#application-error-responses-toerrorresponse), answering 404 `no note <id>`. `tests/test_openapi.mojo` checks each kind's exact output below.

## Building with `-D MUNTIN_OPENAPI`

- Only a build with `-D MUNTIN_OPENAPI` (`mojo build -D MUNTIN_OPENAPI app.mojo`) links the operations; without it, a call does not compile: `constraint failed: openapi: build with -D MUNTIN_OPENAPI`. A build without the define links none of the operations.
- `openapi` is the `App`'s: a `Group`'s routes are described once mounted, and `group.openapi(...)` does not compile: `constraint failed: openapi: mount the Group first`.

## The document

- `openapi` is `"3.1.0"`; `info` holds `title` and `version`, then `document`'s `info` members (below).
- `paths` has one path item per route path, in registration order (a group's routes where it was mounted): the literal's path part, placeholders as written (`/notes/{id}` for `/notes/{id}?{tag}`). The path item holds one operation per route, named by its method in lowercase, in registration order. `HEAD` is not described.
- An operation holds `parameters`, a `requestBody` when the handler takes a body, and `responses`, then the application's additions.

### Parameters

Each route value is a parameter named by its placeholder, in binding order: bare, in a `Param`, or a field of a `RouteValues` record ([route values](route-values.md)). A path placeholder is `"in":"path"`, a query placeholder `"in":"query"`.

| Value | Parameter |
|---|---|
| `Int` | `"required":true`, `{"type":"integer","format":"int64","minimum":-9223372036854775808,"maximum":9223372036854775807}` |
| `String`, a `FromRouteValue` type | `"required":true`, `{"type":"string","minLength":1}` (the decoded text, never empty) |
| `Optional[Int]`, `Optional[String]` | `"required":false`, `"allowEmptyValue":true`, the description `An empty value is the same as an absent one.`, and the schema of `Int` or `String` |

`Headers`, a `State`, a raw `Request` and a guard's context add no parameter; header fields are not described.

### Request bodies

| Body, bare or in `WithHeaders` | `requestBody` |
|---|---|
| `Json[T]` | `"required":true`, `application/json` with the schema of what `T`'s reader takes |
| a `FromBody` type | `"required":false`, `*/*` with `{"type":"string"}`: Muntin checks no `Content-Type`, and the type decides about an empty body |
| a `FromBytes` type | `"required":false`, `*/*` with no schema |

A raw handler reads the body itself: its operation has no `requestBody` unless an addition gives one.

### Responses

| Result | Response |
|---|---|
| `String`, `StaticString` | `200`, `*/*` with `{"type":"string"}` |
| `Json[T]` | `2XX`, `application/json` with the schema of what `T`'s writer writes: the status is chosen at run time (`Json(value, status=201)`), and Muntin's own answers are never 2xx |
| `Response`, a `ToResponse` type | `default`, described `Not described: the handler's response` |

Not described unless an addition says so: a `Json` answer of a status outside 2xx, Muntin's own answers (400, 404, 405, 413, 415, 500), a `ToErrorResponse` error's answer, a guard's refusal and what middleware changes.

### Schemas

The schemas follow the derived codec's rules ([JSON bodies](bodies.md#json-jsont)) and are written inline:

| Kind | Schema |
|---|---|
| `Int` | `{"type":"integer","format":"int64"}` with `Int`'s bounds |
| `Float64` | `{"type":"number","format":"double"}` |
| `Bool`, `String` | `{"type":"boolean"}`, `{"type":"string"}` |
| a `JsonFields` struct | `"type":"object"`, its fields as `properties` in field order; read, `required` names every field but an `Optional`'s and other members are allowed; written, `required` names every field and `"additionalProperties":false` |
| `List[E]` | `{"type":"array","items":E}` |
| `Optional[E]` | `{"anyOf":[E,{"type":"null"}]}` |
| a hand-written direction (`FromJson` read, `ToJson` written), a struct's or a field's | `{}`, any value |

A schema admits more than the reader where JSON Schema cannot say it: `1.0` as an `Int`, a repeated member name, Muntin's nesting and size limits. A `Json` answer of 204, 205 or 304 carries a body (`Json.to_response` writes one whatever the status), which no response describes truly; a bodiless answer is a `Response`, described through an addition.

## Additions

The application adds what the types cannot say as JSON text, merged as written: member order and number literals are kept, and nothing is checked against OpenAPI.

- `document`: a JSON object whose members go at the top level after `paths` (`servers`, `security`, `components`), but for `info`, whose members go into `info` after `title` and `version` (`summary`, `description`, `license`).
- `operations`: a `Dict[String, String]` keyed `METHOD path` (`"GET /notes/{id}"`, the method in uppercase and the document's path); each value is a JSON object whose members go into that operation after the derived ones (`summary`, `security`, `tags`), but for `responses`, whose members go into `responses` after the derived one. An explicit status (`404`) takes precedence over `2XX` in OpenAPI.

`openapi` raises when an addition is not a JSON object, names no route, or repeats a derived member:

- `openapi: document is not JSON: <the parser's message>`, `openapi: document is not a JSON object`, and the same with `operations[GET /notes/{id}]` for an operation's;
- `openapi: operations: no route GET /nowhere`;
- `openapi: document: openapi is derived`, the same for `paths`; `openapi: document: info: title is derived`, the same for `version`; `openapi: document: info: not a JSON object`;
- `openapi: operations[POST /notes]: parameters is derived` for any operation; `requestBody is derived` when the handler takes a body; `200 is derived`, `2XX is derived` or `default is derived` for the status its result gives; `not a JSON object` for `responses` that is not one.

## Routes that cannot be described

`openapi` raises, naming the route, when the document could not say truly what `App.handle` does:

- a path placeholder repeated in a path, which OpenAPI does not allow: `openapi: route /pairs/{id}/{id} repeats the placeholder {id}, which OpenAPI does not allow`;
- two paths that differ only in placeholder names, which OpenAPI treats as one path: `openapi: routes /users/{id} and /users/{name} differ only in placeholder names, which OpenAPI treats as one path`;
- a query key or static segment that common clients do not send as written, since Muntin compares it undecoded: `openapi: route /f?{filter[name]}: a client may not send the query key filter[name] as written, and Muntin compares it undecoded`, and `openapi: route /hello world: a client may not send the segment hello world as written, and Muntin matches it undecoded`. A query key is sent as written when it holds only letters, digits and `-._`; a static segment when it holds only letters, digits, `-._~`, `!$&'()*+,;=`, `:`, `@` and `%` followed by two hexadecimal digits, and is not a dot segment (`.` or `..`, also written with `%2e` or `%2E`), which a client removes.
