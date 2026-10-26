# Request bodies

A typed `post`, `put` or `patch` handler takes one body, as its last parameter, after at most two route values (or one record) and after any `State` ([routing](routing.md#registering-a-route)). A body is one of:

- a `FromBody` type: text the application parses;
- `Json[T]` with `T: FromJson`: JSON parsed by Muntin's codec;
- a `FromBytes` type: the body's bytes;
- `WithHeaders[B]` around one of these: the body and the request's header fields.

Each has a size limit, a type's `max_bytes` or `Json[T, limit=n]`, and a longer body is 413 ([body size limits](body-limits.md)).

The body comes from the request body only, never from the path or query, byte for byte. A conversion that raises is 400 `Bad Request` and the handler is not called; the error's text is not sent, only kept in the 400's report, which tells a body that is not UTF-8 or, for `Json[T]`, not JSON from a conversion's raise ([errors](errors.md#reports-of-rejected-requests)). The order of checks is in [routing](routing.md#order-of-checks). A handler without a body on these methods is bodyless ([routing](routing.md#bodyless-post-put-and-patch)); a raw handler reads any body itself ([raw handlers](raw.md)).

Each example below is its own `App` (named `app`, created with `var app = App()`), so the same route or type name (`POST /users`, `create_user`, `CreateUser`, `Unauthorized`) means that example's own; the line after it names the test that runs it and what that test adds or changes.

## Text bodies (`FromBody`)

<!-- example: tests/test_reference_examples.mojo#bodies-text-body -->
```mojo
from muntin import App, FromBody


struct CreateUser(FromBody):              # defined by the application; may be move-only
    var name: String

    def __init__(out self, name: String):
        self.name = name

    @staticmethod
    def from_body(body: String) raises -> Self:   # the application owns the body format
        if not body.startswith("name=") or body.byte_length() == 5:
            raise Error("expected name=<text>")
        return Self(String(body[byte=5:]))


def create_user(body: CreateUser) -> String:      # `var body: CreateUser` also works
    return "created " + body.name


var app = App()
app.post["/users"](create_user)
# POST /users  "name=Ada"       -> 200 "created Ada"   (create_user received the converted value)
# POST /users  "Ada" or ""      -> 400 "Bad Request"   (from_body raised; create_user not called)
# GET /users, PUT /users      -> 405 "Method Not Allowed", Allow: POST (from_body not called)
# POST /missing                -> 404 "Not Found" (from_body not called)
```

Run by `tests/test_reference_examples.mojo` (`test_bodies_text_body`), as written. That `from_body` and `create_user` are not called is checked by `tests/test_body.mojo` (`test_invalid_body_is_400_without_calling_the_handler`, `test_method_mismatch_is_405_and_unmatched_path_404_without_conversion`), on an app with more routes.

- `FromBody` refines `Deinitable & Movable` with one requirement, `@staticmethod def from_body(body: String) raises -> Self`, and `comptime max_bytes: Int = 1_048_576`. The type conforms in its own module; Muntin never names it. `from_body` sees the body only, as one `String`, not the header fields (use `WithHeaders[B]` for those).
- Muntin reads the body's bytes as strict UTF-8 first: bytes that are not well-formed UTF-8 are 400 before `from_body`, never replaced by U+FFFD. An empty body, whitespace, NUL and a U+FFFD the client sent reach `from_body` unchanged. A body over the type's `max_bytes`, 1 MiB unless it declares another, is 413 before this read ([body size limits](body-limits.md#text-bodies-frombody)).

### A route value, then the body

<!-- example: tests/test_reference_examples.mojo#bodies-route-value-then-body -->
```mojo
from muntin import App, FromBody


struct UpdateUser(FromBody):              # the name=<text> format of CreateUser above; may be move-only
    var name: String

    def __init__(out self, name: String):
        self.name = name

    @staticmethod
    def from_body(body: String) raises -> Self:
        if not body.startswith("name=") or body.byte_length() == 5:
            raise Error("expected name=<text>")
        return Self(String(body[byte=5:]))


def update_user(id: Int, body: UpdateUser) -> String:   # `var body: UpdateUser` also works
    return "user " + String(id) + " " + body.name


app.post["/users/{id}"](update_user)      # route value from a path segment
app.post["/users?{id}"](update_user)      # or from a query item
# POST /users/042     "name=Ada"  -> 200 "user 42 Ada"
# POST /users?id=042  "name=Ada"  -> 200 "user 42 Ada"
# POST /users/abc, /users?id=1&id=2, /users  (any body) -> 400 "Bad Request"  (from_body and update_user not called;
#                                    /users matches the query route's path, so its missing id is 400)
# POST /users/1       "Ada"       -> 400 "Bad Request"  (from_body raised; update_user not called)
# PUT /users/1                    -> 405 "Method Not Allowed", Allow: POST  (nothing converted)
# POST /users/1/x                 -> 404 "Not Found"    (nothing converted)
```

Run by `tests/test_reference_examples.mojo` (`test_bodies_route_value_then_body`), as written; it sends each 400 target with the bodies `name=Ada`, `Ada` and `""`, and `PUT /users/1` with `name=Ada`. That `from_body` and `update_user` are not called is checked by `tests/test_int_body.mojo` (`int_body_app()`, with `test_path_value_then_body`, `test_query_value_then_body`, `test_bad_route_value_is_400_before_body_conversion`, `test_bad_body_is_400_without_the_handler` and `test_method_mismatch_is_405_and_unmatched_path_404_without_extraction`), whose `UpdateUser` and `update_user` also count their calls in environment variables. Its app also registers `GET /users/{id}` and `/notes`, `/people`, `/moves` and `/acks` routes, so its 405 check sends `PUT`, `PATCH` and `DELETE /users/1` and expects `Allow: GET, HEAD, POST`; with the example's two routes alone the answer is `Allow: POST`.

The route values convert first; an invalid one is 400 and the body is not converted.

### Body errors

- `constraint failed: the handler's parameter is the request body; its type must conform to FromBody or FromBytes` (`the handler's last parameter ...` after a route value), for any other type, `List[UInt8]` included.
- `constraint failed: a post handler takes one request body, as its last parameter` for a body before a route value or two bodies.
- `constraint failed: handler takes only the request body; route must declare no path or query parameter` for a placeholder with no route-value parameter.
- `constraint failed: a get handler takes no request body` (`a delete handler ...`) for a body on `get` or `delete`.
- A type conforming to both `FromBody` and `FromBytes` is `the request body's type conforms to both FromBody and FromBytes; a body type conforms to one of them`.

## JSON (`Json[T]`)

The application wraps its own type in `Json[T]`, which is a body and a [result](responses.md#json-results); registration is unchanged. A struct that conforms to `JsonFields` is read and written from its fields:

<!-- example: tests/test_json_dx.mojo#bodies-json-derived -->
```mojo
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


app.post["/notes"](create_note)
app.post["/notes/import"](import_notes)
# POST /notes  Content-Type: application/json  {"text":"hi","tags":["a"]}
#   -> 201, Content-Type: application/json, {"id":1,"text":"hi","tags":["a"],"due":null}
# POST /notes/import  [{"text":"a","tags":[]},{"text":"b","tags":[],"due":3}]
#   -> 200, [{"id":1,"text":"a","tags":[],"due":null},{"id":2,"text":"b","tags":[],"due":3}]
# {"tags":[]} -> 400 "Bad Request"; its Rejection: from_json: text: JSON member is missing
# [{"text":"a","tags":[1]}] -> 400; its Rejection: from_json: [0].tags[0]: JSON value is not a string
```

Run by `tests/test_json_dx.mojo` (`test_derived_json_example`), as written; it also posts a `null` `due`, read as empty. Every kind, ownership, a hand-written direction and each failure's report on a bare, carried, guarded and stateful body: `tests/test_derived_json.mojo`.

- A field is an `Int`, `Float64`, `Bool`, `String`, a `FromJson` type (read) or `ToJson` type (written), a `JsonFields` struct, or a `List` or `Optional` (not of an `Optional`) of one. Its member is named after it (`` var `created-at`: Int `` is `created-at`); there is no renaming or default: for those, write that direction by hand (below).
- Reading: an `Optional` member may be absent or `null`; every other member is required; unknown members are ignored. Writing: every member in field order, an empty `Optional` as `null`. A struct with no field reads any object and writes `{}`.
- `Json[T]` also takes a top-level `List` or `Optional` of any of these, as a body and as a result (`Json[Optional[Note]]` reads and writes `null` as empty).
- **`JsonFields` is for a receiving DTO: a struct for which any combination of field values is valid to hold, use and destroy.** Muntin builds it without running any of its initializers; conforming consents to that, as for [`RouteValues`](route-values.md#route-value-records). What `__init__` guarantees does not hold: a `Range` whose `__init__` requires `start <= end` is built from `{"start":10,"end":0}`, and its methods and destructor see that value, even after the handler rejects it. A type with an invariant does not conform: read a DTO, check it, and build the type with its own constructor, or read the type with a hand-written `from_json` that checks and constructs. A failure part-way destroys each field already read, once; the struct's destructor does not run.
- A hand-written `FromJson` or `ToJson` on the struct takes that direction over. The reverse works too: a hand-written codec reads and writes a derived value ([responses](responses.md#derived-values-inside-a-hand-written-codec)).
- A field that cannot be read (a body) or written (a result) is refused at the registration, naming the innermost one: `constraint failed: field zip of the JsonFields struct <module>.Place has type SIMD[DType.uint8, 1], which cannot be read: a derived field is an Int, Float64, Bool, String, a FromJson type, a JsonFields struct, or a List or Optional of one`; a raw handler's `Json[T].from_body` is refused alike where it is called. Another top-level type is `Json[<type>] cannot be read` (or `written`). Not supported: `Dict`, other widths (`Int64`, `Float32`), `Optional[Optional[T]]`, and a struct holding a `List` of itself (Mojo 1.1.0 rejects the struct).
- A body that does not read is 400, and its [report](errors.md#reports-of-rejected-requests)'s message starts with the member path (`notes[2].text: JSON value is not a string`, `[0].tags[0]: ...`); a top-level value of the wrong kind has none. `Json[T].from_body` raises the same text.

### Hand-written codecs (`FromJson`, `ToJson`)

For another representation (renamed or defaulted members, a check while reading), the application declares `FromJson`/`ToJson` on its own type:

<!-- example: tests/test_json_dx.mojo#bodies-json -->
```mojo
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


app.post["/users"](create_user)          # body only
app.post["/users/{id}"](replace_user)    # route value, then body
# POST /users  Content-Type: application/json  {"name":"Ada","age":36}
#   -> 200, Content-Type: application/json, {"id":1,"name":"Ada"}
# Content-Type missing, text/plain, two fields, or application/problem+json
#   -> 415 "Unsupported Media Type" (before parsing and the handler)
# a body over 1 MiB -> 413 "Content Too Large" (after the 415 check, before parsing)
# application/json; charset=utf-8 -> accepted (parameters are not interpreted)
# malformed JSON, a missing member, a wrong kind -> 400 "Bad Request"
```

Run by `tests/test_json_dx.mojo` (`test_dx_json_examples`), with these types and handlers as written; its app also registers `GET /create` (the media-type example of [responses](responses.md#json-results)), and it also posts `{"name":"Bo","age":1,"nickname":null}` to `/users/4` (`{"id":4,"name":"Bo"}`). It does not check that 415 is answered before 413.

- `value[name]` raises naming the missing member (`JSON member "name" is missing`); `int()` and `float()` do not quote the literal. `value.read[T](name)` reads a derived value ([responses](responses.md#derived-values-inside-a-hand-written-codec)).

### Rules for every JSON body

- `Content-Type`: exactly one field whose media type (before any `;`, trimmed) is `application/json`, ASCII case-insensitively; parameters are ignored. Missing, repeated, other and `+json` types are 415.
- Size: at most 1,048,576 bytes unless `Json[T, limit=n]` says otherwise; one more is 413. `Json[T].from_body` also raises above it in a raw handler ([body size limits](body-limits.md#json-bodies-jsont-limitn)).
- Grammar: RFC 8259, strictly. Comments, trailing commas, leading zeros, `NaN`, duplicate member names, a byte order mark, lone surrogates and nesting deeper than 64 are 400. Extra members are ignored.
- Numbers: `int()` is exact for integer literals that fit `Int`. `float()` rounds a literal of any length to the nearest `Float64`, ties to even. It raises (400) only when that rounding gives infinity, at a magnitude of 2^1024 − 2^970 or more, so `1.7976931348623158e308` reads as the largest double; a magnitude of 2^-1075 or less rounds to a zero of the literal's sign, so `2.4703282292062328e-324` reads as the smallest subnormal.
- A `FromJson` or `JsonFields` type is not a body by itself (`def create_user(body: CreateUser)` gets the `FromBody or FromBytes` message).
- Ownership: borrow (`body.value`) or own and move out (`var body`, `body^.take()`); `body.value^` does not compile.
- Cost: parsing is linear apart from a sort of each object's member names; reading k fields of an m-member object costs O(k·m), by hand or derived. At 1 MiB a parse adds up to about 29 MB of memory (1 MiB of `[0,0,...]`), about 5 MB for typical records. `float()` converts the literal on every call, so its cost follows the calls, not the body: about a microsecond for a short literal near either end of the range, more for hundreds of digits ([#176](https://github.com/sano-suguru/muntin/pull/176) measures it).
- `TestClient.post(target, body)` sends no fields, so it gets 415; send `headers=` with the `Content-Type` ([testing](testing.md)).

## Header fields with a body (`WithHeaders[B]`)

A handler that needs header fields takes `WithHeaders[B]` where it would take the body `B`:

<!-- example: tests/test_with_headers.mojo#bodies-with-headers -->
```mojo
from muntin import App, FromBody, Json, Response, State, ToErrorResponse, WithHeaders

# CreateUser (FromJson) and User (ToJson): the JSON example above.


@fieldwise_init
struct Unauthorized(ToErrorResponse):
    def to_error_response(deinit self) -> Response:
        return Response.text("Unauthorized", status=401)


struct Users(Movable):                    # application state: the one allowed token
    var token: String

    def __init__(out self, token: String):
        self.token = token

    def allows(self, token: String) -> Bool:
        return token == self.token


struct Note(FromBody, Movable):           # an application FromBody; move-only
    var text: String

    def __init__(out self, var text: String):
        self.text = text^

    @staticmethod
    def from_body(body: String) raises -> Self:
        if body == "bad":
            raise Error("bad body")
        return Self(body)


def create_user(
    users: State[Users], input: WithHeaders[Json[CreateUser]]
) raises Unauthorized -> Json[User]:
    var token = input.headers.get("authorization")    # Optional[String]
    if not token or not users[].allows(token.value()):    # a read-only Users method
        raise Unauthorized()                          # ToErrorResponse: 401
    return Json(User(1, input.body.value.name))


def update_note(id: Int, var input: WithHeaders[Note]) -> String:
    var traces = input.headers.get_all("x-trace")     # every value, in order
    var note = input^.take_body()                     # the body, moved out
    return String(id, " ", note.text, " traces=", len(traces))


var users = State(Users("secret"))
app.post["/users"](create_user, users)                # stateful, body only
app.post["/notes/{id}"](update_note)                  # route value, then body
# POST /users  Content-Type: application/json  Authorization: secret  {"name":"Ada","age":36}
#   -> 200, {"id":1,"name":"Ada"}
# Authorization missing or not "secret" -> 401 "Unauthorized" (the handler's error type)
# Content-Type missing -> 415, before the handler (the JSON rules above, unchanged)
# POST /notes/3  X-Trace: a  x-trace: b  "hi" -> 200 "3 hi traces=2"
```

Run by `tests/test_with_headers.mojo` (`test_dx_typed_header_access_example`), with these types and handlers and the JSON example's `CreateUser` and `User` as written; it also checks `POST /notes/x` is 400.

- `input.headers` is the request's [`Headers`](headers.md). **Muntin gives the fields no meaning and chooses no status for them**: a missing field is `None`, there is no pre-handler 400 for a field, and the handler answers it through its error type (401, 412, 428, 400 as the field requires). Two existing checks still answer before the handler: a `Json[T]` body's `Content-Type` verdict (415), and the rebuild of a field an in-memory `Headers` holds invalidly (the fixed 500; [headers](headers.md#headers), known gap).
- `input.body` is converted exactly as a bare body of its type. Own the carrier (`var input`) to move the body out with `input^.take_body()`; `input.body^` does not compile.
- Every shape that takes a body takes the carrier. It is not a `get` handler (`get` reads fields through a `Headers` parameter).
- `WithHeaders` is not a `FromBody` or a `FromBytes`, so generic code bounded by either does not accept it; build one by hand with `WithHeaders(body^, headers^)`. Its `B` must be a `FromBody` or a `FromBytes`; `WithHeaders[Int]` is rejected where the handler is declared (`'WithHeaders' parameter 'B' has '_FromBodyOrBytes' type, but value has type 'AnyStruct[Int]'`).
- Cost: the route copies each field name and value twice per request and validates each field again.

## Binary bodies (`FromBytes`)

A body that is not text is a `FromBytes` type, which receives the body's bytes, whatever they are:

<!-- example: tests/test_bytes_body.mojo#bodies-bytes -->
```mojo
from muntin import App, FromBytes


struct Image(FromBytes):
    comptime max_bytes = 1 << 20  # a longer body is 413, before from_bytes

    var data: List[UInt8]

    def __init__(out self, var data: List[UInt8]):
        self.data = data^

    @staticmethod
    def from_bytes(body: List[UInt8]) raises -> Self:
        # A sketch, not a PNG validator: only the length and two bytes.
        if len(body) < 8 or body[0] != 0x89 or body[1] != 0x50:
            raise Error("not a PNG")  # 400, upload not called
        return Self(body.copy())  # the bytes are borrowed: keep a copy


def upload(image: Image) -> String:  # `var image: Image` also works
    return String(len(image.data), " bytes")


app.post["/upload"](upload)
# POST /upload  89 50 4E 47 0D 0A 1A 0A 00 FF 80 -> 200 "11 bytes"  (from_bytes received the 11 bytes)
# POST /upload  "GIF89a"                         -> 400 "Bad Request"  (from_bytes raised; upload not called)
# GET /upload                                    -> 405 "Method Not Allowed", Allow: POST  (from_bytes not called)
```

Run by `tests/test_bytes_body.mojo` (`test_dx_example`), with `Image` and `upload` as written.

- `FromBytes` refines `Deinitable & Movable` with `comptime max_bytes: Int` and `@staticmethod def from_bytes(body: List[UInt8]) raises -> Self` (a non-raising one conforms too); `max_bytes` and its examples: [body size limits](body-limits.md#binary-bodies-frombytes).
- `from_bytes` receives `Request.body` itself, borrowed and read-only: the bytes as received or as middleware replaced them, with no UTF-8 check and no copy. A type that keeps them copies them (`body.copy()`).
- Every shape that takes a `FromBody` takes a `FromBytes`. There is no `Content-Type` rule.
- With header fields, wrap it: `WithHeaders[B]` around a `FromBytes` follows the carrier's rules above.

<!-- example: tests/test_bytes_headers_body.mojo#bodies-bytes-with-headers -->
```mojo
from muntin import App, FromBytes, Response, ToErrorResponse, WithHeaders


struct Upload(FromBytes):
    comptime max_bytes = 8 << 20  # a longer body is 413, before from_bytes

    var data: List[UInt8]

    def __init__(out self, var data: List[UInt8]):
        self.data = data^

    @staticmethod
    def from_bytes(body: List[UInt8]) raises -> Self:
        if len(body) == 0:
            raise Error("empty upload")  # 400, put_object not called
        return Self(body.copy())  # the bytes are borrowed: keep a copy


@fieldwise_init
struct Unauthorized(ToErrorResponse):
    def to_error_response(var self) -> Response:
        return Response.text("missing signature", status=401)


def put_object(
    key: String, input: WithHeaders[Upload]
) raises Unauthorized -> String:
    var signature = input.headers.get("x-signature")
    if not signature:
        raise Unauthorized()  # Muntin gives the field no meaning
    var kind = input.headers.get("content-type").or_else("unknown")
    return String(key, ": ", len(input.body.data), " bytes, ", kind)


app.put["/objects/{key}"](put_object)
# PUT /objects/logo.png  X-Signature: s1  Content-Type: image/png  89 50 00 FF 80
#   -> 200 "logo.png: 5 bytes, image/png"   (from_bytes received the 5 bytes)
# the same without X-Signature  -> 401 "missing signature"  (the handler's error type)
# X-Signature: s1, empty body   -> 400 "Bad Request"  (from_bytes raised; put_object not called)
# no X-Signature, empty body    -> 400 "Bad Request"  (from_bytes runs before put_object reads the field)
# GET /objects/a                -> 405 "Method Not Allowed", Allow: PUT
```

Run by `tests/test_bytes_headers_body.mojo` (`test_dx_example`), with `Upload`, this `Unauthorized` and `put_object` as written; its requests without `X-Signature` go to `/objects/a`.

**A field the handler checks is read after the conversion.** `from_bytes` runs on every request the route selects, signed or not. When the conversion is costly or must not see unauthenticated input, check the field in a [guarded group](groups.md)'s guard, which runs after routing and before the conversion, in middleware, which answers before routing and conversion (scope it by `request.path` and `request.method`, since it also answers ahead of 404 and 405), or in a raw handler.
