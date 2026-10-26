# Body size limits

Every typed body's type has a size limit in bytes (`Int.MAX` is none). A longer body is 413 `Content Too Large` before the conversion and the handler, bare or in `WithHeaders[B]`: after the route values, before a carrier's field rebuild and before a text body's UTF-8 read ([order of checks](routing.md#order-of-checks)).

| Body | Its limit | When it declares none |
|---|---|---|
| a `FromBody` type | its `comptime max_bytes` | 1,048,576 bytes (1 MiB) |
| `Json[T]` | `Json[T, limit=n]` | 1 MiB |
| a `FromBytes` type | its `comptime max_bytes` | does not compile, unless a refining trait gives a default |

Each example below is its own `App` (named `app`, created with `var app = App()`), as on [request bodies](bodies.md).

## Text bodies (`FromBody`)

<!-- example: tests/test_bytes_limit.mojo#body-limits-text -->
```mojo
from muntin import App, FromBody


struct Article(FromBody):
    comptime max_bytes = 8 << 20  # a longer body is 413, before the UTF-8 read

    var text: String

    def __init__(out self, var text: String):
        self.text = text^

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


struct Comment(FromBody):  # declares no max_bytes: 1 MiB
    var text: String

    def __init__(out self, var text: String):
        self.text = text^

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def publish(id: Int, article: Article) -> String:
    return String(id, ": ", article.text.byte_length(), " bytes")


def add_comment(id: Int, comment: Comment) -> String:
    return String(id, ": ", comment.text.byte_length(), " byte comment")


app.put["/articles/{id}"](publish)
app.post["/articles/{id}/comments"](add_comment)
# PUT /articles/7  8,388,608 bytes  -> 200 "7: 8388608 bytes"
# PUT /articles/7  8,388,609 bytes  -> 413 "Content Too Large"  (from_body and publish not called, UTF-8 or not)
# POST /articles/7/comments  1,048,576 bytes -> 200 "7: 1048576 byte comment";  1,048,577 bytes -> 413
```

Run by `tests/test_bytes_limit.mojo` (`test_dx_text_and_json_examples`), as written, in the same app as the JSON example below; its 413 for `PUT /articles/7` is checked with a body of `a`s and with bytes that are not UTF-8. It checks the statuses and texts, not which functions ran.

- `FromBody` gives `max_bytes` a default of 1 MiB, so a type that declares none, or misspells it (`max_byte`), is limited, never unlimited. `Int.MAX` is no limit; `0` accepts only the empty body.
- A trait refining `FromBody` cannot give its family another default: Mojo 1.1.0 rejects the type (`trait member 'max_bytes' has conflicting default implementations`). Declare it on each type; a type parameter gives one type a limit per route, as `Blob` below.

## JSON bodies (`Json[T, limit=n]`)

<!-- example: tests/test_bytes_limit.mojo#body-limits-json -->
```mojo
from muntin import App, Json, JsonFields


@fieldwise_init
struct NewPost(JsonFields):
    var title: String


def create_post(post: Json[NewPost, limit=64 * 1024]) -> String:
    return "posted " + post.value.title


def import_posts(posts: Json[List[NewPost], limit=8 << 20]) -> String:
    return String(len(posts.value), " posts")


app.post["/posts"](create_post)
app.post["/posts/import"](import_posts)
# POST /posts  Content-Type: application/json  65,536 bytes -> 200 "posted a";  65,537 bytes -> 413
#   (after the 415 check, before parsing)
# POST /posts/import  Content-Type: application/json  2 MiB -> 200 (Json[T] alone: 413 past 1 MiB)
```

Run by `tests/test_bytes_limit.mojo` (`test_dx_text_and_json_examples`), as written; its import posts an array of two `{"title":"a"}` padded with spaces to 2 MiB (`2 posts`), and it also checks that a 65,537-byte post without `Content-Type` is 415.

- `limit` is keyword-only (`Json[T, 4096]` does not compile) and is 1 MiB unless given: `Json[T]` is `Json[T, limit=1048576]`. At most 4,294,967,295 (2^32 − 1), the longest body the parser addresses; a larger one fails where the route is registered (`Json's limit is over 4294967295 bytes, the longest body its parser addresses`).
- `Json[T, limit=n].from_body` raises above `n` (`JSON body too large`), so a raw handler that calls it gets the same bound.
- A parse's memory grows with the limit: about 29 MB at 1 MiB ([JSON rules](bodies.md#rules-for-every-json-body)).
- On a result `limit` means nothing: the whole value is written. It is part of the type, so a handler that returns its body returns `Json[T, limit=n]`.

## Binary bodies (`FromBytes`)

Every `FromBytes` type declares the longest body it accepts:

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

- `max_bytes` is required, with no default in `FromBytes`: a type whose traits give `max_bytes` no default and that declares none, or misspells it (`max_byte`), does not conform (`required member 'max_bytes' is not specified`). `Int.MAX` is no limit; `0` accepts only the empty body.
- **Under a refining trait's default the compiler no longer catches a misspelling**: `comptime max_byte = 4096` compiles and inherits the family's value. Give a family a finite default, the strictest its types share, never `Int.MAX`, and check an override where the type is declared (`comptime assert Banner.max_bytes == 4096`).

## Every limit

- A negative `max_bytes` or `limit` is rejected at registration (`the request body's max_bytes is negative; a body type's max_bytes is a byte count, 0 or more`).
- It is `App.handle`'s rule, not the type's: `Avatar.from_bytes(bytes)` or `Comment.from_body(text)` called directly checks no limit (`Json[T].from_body` checks its own). It measures `Request.body` after middleware.
- It bounds what reaches the conversion, not what the server receives: the backend has already buffered the whole body. Receiving is bounded by the `Server`'s `max_body_bytes` ([serving](serving.md#receive-body-limit)); a limit above it is never reached.
- There is no `App`-wide or per-registration limit. A raw handler measures `req.body` itself ([raw handlers](raw.md)).
