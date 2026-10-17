# Request bodies

A typed `post`, `put` or `patch` handler takes one body, as its last parameter, after at most two route values (or one record) and after any `State` ([routing](routing.md#registering-a-route)). A body is one of:

- a `FromBody` type: text the application parses;
- `Json[T]` with `T: FromJson`: JSON parsed by Muntin's codec;
- a `FromBytes` type: the body's bytes, with a declared size limit;
- `WithHeaders[B]` around one of these: the body and the request's header fields.

The body comes from the request body only, never from the path or query, byte for byte. A conversion that raises is 400 `Bad Request` and the handler is not called. The order of checks is in [routing](routing.md#order-of-checks). A handler without a body on these methods is bodyless ([routing](routing.md#bodyless-post-put-and-patch)); a raw handler reads any body itself ([raw handlers](raw.md)).

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

- `FromBody` refines `Deinitable & Movable` with one requirement, `@staticmethod def from_body(body: String) raises -> Self`. The type conforms in its own module; Muntin never names it. `from_body` sees the body only, as one `String`, not the header fields (use `WithHeaders[B]` for those).
- Muntin reads the body's bytes as strict UTF-8 first: bytes that are not well-formed UTF-8 are 400 before `from_body`, never replaced by U+FFFD. An empty body, whitespace, NUL and a U+FFFD the client sent reach `from_body` unchanged. Text bodies have no Muntin size limit, `Json[T]` keeps its fixed 1 MiB step ([below](#json-jsont)), and raw handlers measure `req.body` themselves; the `Server`'s `max_body_bytes` applies over the wire ([serving](serving.md#receive-body-limit)).

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

The application declares `FromJson`/`ToJson` on its own types and wraps them in `Json[T]`, which is a body and a [result](responses.md#json-results); registration is unchanged:

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
        out.name("id")
        out.int(self.id)
        out.name("name")
        out.string(self.name)
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

- `Content-Type`: exactly one field whose media type (before any `;`, trimmed) is `application/json`, ASCII case-insensitively; parameters are ignored. Missing, repeated, other and `+json` types are 415.
- Size: at most 1,048,576 bytes; one more is 413 (fixed). `Json[T].from_body` also raises above it in a raw handler.
- Grammar: RFC 8259, strictly. Comments, trailing commas, leading zeros, `NaN`, duplicate member names, a byte order mark, lone surrogates and nesting deeper than 64 are 400. Extra members are ignored.
- Numbers: `int()` is exact for integer literals that fit `Int`. `float()` goes through Mojo 1.1.0's `atof`: long literals raise (400) and some values come back 1 ulp off; read exact values with `int()`.
- Fields are mapped by hand in `from_json`; there is no derived codec. A `FromJson` type is not a body by itself (`def create_user(body: CreateUser)` gets the `FromBody or FromBytes` message).
- Ownership: borrow (`body.value`) or own and move out (`var body`, `body^.take()`); `body.value^` does not compile.
- Cost: parsing is linear apart from a sort of each object's member names; reading k fields of an m-member object costs O(k·m). At the cap a parse adds up to about 29 MB of memory (1 MiB of `[0,0,...]`), about 5 MB for typical records.
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

- `FromBytes` refines `Deinitable & Movable` with `comptime max_bytes: Int` and `@staticmethod def from_bytes(body: List[UInt8]) raises -> Self` (a non-raising one conforms too).
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

**A field the handler checks is read after the conversion.** `from_bytes` runs on every request the route selects, signed or not. When the conversion is costly or must not see unauthenticated input, check the field in middleware, which answers before routing and conversion (scope it by `request.path` and `request.method`, since it also answers ahead of 404 and 405), or in a raw handler.

### Body size limits (`max_bytes`)

Every `FromBytes` type declares the longest body it accepts, in bytes; a longer body is 413 `Content Too Large` before `from_bytes`, bare or carried:

<!-- example: tests/test_bytes_limit.mojo#bodies-limit-avatar -->
```mojo
from muntin import App, FromBytes, WithHeaders


struct Avatar(FromBytes):
    comptime max_bytes = 64 * 1024  # a longer body is 413, before from_bytes

    var data: List[UInt8]

    def __init__(out self, var data: List[UInt8]):
        self.data = data^

    @staticmethod
    def from_bytes(body: List[UInt8]) raises -> Self:
        if len(body) == 0:
            raise Error("empty avatar")  # 400, set_avatar not called
        return Self(body.copy())


def set_avatar(id: Int, avatar: Avatar) -> String:
    return String(id, ": ", len(avatar.data), " bytes")


app.put["/users/{id}/avatar"](set_avatar)
# PUT /users/7/avatar  65,536 bytes  -> 200 "7: 65536 bytes"
# PUT /users/7/avatar  65,537 bytes  -> 413 "Content Too Large"  (from_bytes and set_avatar not called)
# PUT /users/x/avatar  70,000 bytes  -> 400 "Bad Request"  (the route value answers first, whatever the length)
# PUT /users/7/avatar  empty         -> 400 "Bad Request"  (from_bytes raised)
```

Run by `tests/test_bytes_limit.mojo` (`test_dx_examples`), with `Avatar` and `set_avatar` as written; the same app also registers the `Blob` routes below. It checks the statuses and texts, not which functions ran.

A different limit per route is a type parameter; a family of types can share a default through a trait refining `FromBytes` (`trait SmallUpload(FromBytes): comptime max_bytes: Int = 16`):

<!-- example: tests/test_bytes_limit.mojo#bodies-limit-blob -->
```mojo
struct Blob[limit: Int](FromBytes):
    comptime max_bytes = Self.limit  # one type, a limit per route

    var data: List[UInt8]

    def __init__(out self, var data: List[UInt8]):
        self.data = data^

    @staticmethod
    def from_bytes(body: List[UInt8]) raises -> Self:
        return Self(body.copy())


def put_blob(key: String, input: WithHeaders[Blob[1 << 20]]) -> String:
    var kind = input.headers.get("content-type").or_else("unknown")
    return String(key, ": ", len(input.body.data), " bytes, ", kind)


def put_icon(key: String, input: WithHeaders[Blob[4096]]) -> String:
    return String(key, ": ", len(input.body.data), " byte icon")


app.put["/blobs/{key}"](put_blob)
app.put["/icons/{key}"](put_icon)
# PUT /blobs/a.png  Content-Type: image/png  1,048,576 bytes -> 200 "a.png: 1048576 bytes, image/png"
# PUT /blobs/a.png  1,048,577 bytes                          -> 413 "Content Too Large"
# PUT /icons/i  4,096 bytes -> 200 "i: 4096 byte icon";  4,097 bytes -> 413
```

Run by `tests/test_bytes_limit.mojo` (`test_dx_examples`), with `Blob`, `put_blob` and `put_icon` as written, in the same app as the `Avatar` route above; the example's imports are the `Avatar` example's.

- `max_bytes` is required, with no default in `FromBytes`: a type whose traits give `max_bytes` no default and that declares none, or misspells it (`max_byte`), does not conform (`required member 'max_bytes' is not specified`). `Int.MAX` is no limit; `0` accepts only the empty body. A negative value is rejected at registration (`the request body's max_bytes is negative; a FromBytes type's max_bytes is a byte count, 0 or more`).
- **Under a refining trait's default the compiler no longer catches a misspelling**: `comptime max_byte = 4096` compiles and inherits the family's value. Give a family a finite default, the strictest its types share, never `Int.MAX`, and check an override where the type is declared (`comptime assert Banner.max_bytes == 4096`).
- It is `App.handle`'s rule, not the type's: `Avatar.from_bytes(bytes)` called directly checks no limit. It measures `Request.body` after middleware.
- It bounds what reaches `from_bytes`, not what the server receives: the backend has already buffered the whole body. Receiving is bounded by the `Server`'s `max_body_bytes` ([serving](serving.md#receive-body-limit)); a `max_bytes` above it is never reached.
- Only a `FromBytes` type's `max_bytes` is a limit; the same member on a `FromBody` type is ignored. There is no `App`-wide or per-registration limit.
