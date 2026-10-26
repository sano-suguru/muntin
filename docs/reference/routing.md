# Routing and registration

Everything here is Muntin's own answer: what `App.handle` returns when no middleware changes it ([middleware](middleware.md) may answer instead or change any answer, 404 and 405 included). Mojo 1.1.0 (8189361e). Each example below is its own `App`; the line after it names the test that runs it and what that test adds or changes.

## Registering a route

`app.get`, `app.post`, `app.put`, `app.patch` and `app.delete` take a compile-time route literal and a plain `def` handler: `app.get["/users/{id}"](get_user)`. With [application state](state.md) the state is a second argument: `app.get["/users/{id}"](get_user, users)`. There is no `app.head` (a `get` route answers `HEAD`, below) and no other method.

A handler's parameters are request parameters, bound by position: route values first, then a body or `Headers`. Accepted shapes:

| Method | Stateless | Stateful | Result |
|---|---|---|---|
| `get`, `delete` | `def()`, `def(V)`, `def(Headers)`, `def(V, Headers)`, `def(V, V)`, `def(V, V, Headers)` | the same with `State[S]` first | `String`, `StaticString` or `R: ToResponse` |
| `post`, `put`, `patch` | `def(B)`, `def(V, B)`, `def(V, V, B)`, and every `get` shape (bodyless, below) | the same with `State[S]` first | same |
| all five | `def(P)`, `def(P, Headers)`; on `post`, `put`, `patch` also `def(P, B)` | the same with `State[S]` first | same |
| all five | raw `def(Request)` | raw `def(State[S], Request)` | `Response` only |

- `V` is a route value: `Int`, `String`, `Optional[Int]` or `Optional[String]` (a query value only), or an application `FromRouteValue` type, bare or as `Param[name, T]` ([route values](route-values.md)). Two values are both bare or both `Param`s.
- `P` is a `RouteValues` record carrying every route value of its route ([route values](route-values.md#route-value-records)).
- `B` is a body: a `FromBody`, a `FromBytes`, `Json[T]`, or `WithHeaders[B2]` around one of them ([bodies](bodies.md)).
- `Headers` is the request's header fields ([headers](headers.md)); `Request` makes a raw handler ([raw handlers](raw.md)).
- Each handler may be non-raising, `raises` or `raises T` ([errors](errors.md)). Results: [responses](responses.md).

Parameter names are never read (Mojo 1.1.0 cannot reflect them); only a `Param`'s or a record field's name is compared with the placeholder.

## Route literals

A route literal starts with `/` and is `/`-separated segments. A segment is static (matched byte for byte) or `{name}`, which matches one non-empty segment; `name` is any non-empty text without braces. An optional query part after `?` is `{key}` items joined by `&`; a key is non-empty visible ASCII (`!` to `~`) and contains none of `{}=&?#`. A missing leading `/`, `{}`, braces elsewhere, an empty query part, static query text (`?limit`), or a space or non-ASCII byte in a key is a compile error: `constraint failed: malformed route literal`. Query keys in one literal must differ (`constraint failed: route declares a query parameter twice`); path names may repeat and bind by position.

Static path segments are not checked for target bytes: `/hello world` compiles and matches in memory, but never arrives over Flare's HTTP/1.1, which refuses target bytes outside `!`..`~`.

## Matching

- `Request(method, target, body)` splits the target at its first `?`: `request.path` is the text before it and the only thing routes match; `request.query` is the rest, undecoded (`""` without a `?`). Backends pass the target as received. `#` has no meaning (`/items?limit=10#x` has the value `10#x`). An absolute-form target (`http://host/path`) becomes the whole `path` and is 404.
- Matching uses the raw path; a matched value is percent-decoded afterwards ([route values](route-values.md#decoding)), so `%2F` never splits a segment.
- Routes are tried in registration order across methods. A route matches when its method equals the request's byte for byte (a `get` route also matches `HEAD`) and its path matches. The first match handles the request and never falls through, even when it answers 400.
- A path no route matches is 404 `Not Found`. A path that only routes of other methods match is 405 (below).

## Route conflicts

Two overlapping routes of one method register only when the more specific one comes first; a more general route first, the same path twice, or two routes neither of which is more specific (in either order) abort the registration ([M3-053](../history/decisions/m3-053-route-conflict-decision.md)):

<!-- example: tests/test_route_conflicts.mojo#routing-conflicts -->
```mojo
def me() -> String:
    return "me"


def get_user(id: Int) -> String:
    return "user " + String(id)


var app = App()                       # its own App
app.get["/users/me"](me)              # the more specific route first
app.get["/users/{id}"](get_user)      # accepted: it covers /users/me, registered earlier
# GET /users/me -> 200 "me";  GET /users/7 -> 200 "user 7";  GET /users/x -> 400 "Bad Request"
# app.get["/users/me"](me) here instead, after /users/{id}, aborts:
# route conflict: GET /users/me is registered after GET /users/{id}, which matches every request it matches; register GET /users/me first
```

Run by `tests/test_route_conflicts.mojo` (`test_routing_conflicts_example`), as written; `test_first_match_is_the_most_specific` registers these two routes in this order among other routes of other paths and methods. The abort is `tests/route_conflict_abort/parameter_route_first.mojo` (there `get_user` returns `String(id)`), which `scripts/check.sh` runs and requires to abort with that message.

- Two routes of one method overlap when some path matches both: the same number of segments, and at each position equal static text or a `{name}` facing a `{name}` or a non-empty segment (`/` and `/{name}` do not overlap). Placeholder names, the query part and the handler's kind take no part.
- A registration that overlaps an earlier route of its method aborts the program at that call unless the earlier route is more specific (it matches only paths the new one matches, and not all of them). So the same path again (`... matches the same requests as ...`), a more general route first, and two routes neither of which covers the other (`... both match some requests and neither is more specific`) abort; the message names the method and both paths.
- So the first route that matches a request is always the most specific one: registering routes from several modules in another order either answers every request the same way or aborts at registration.
- The check runs when the registration runs, not at compile time. An application that registers every route before serving stops before answering anything; registering after `handle` is allowed, and a conflict found then aborts after the requests already answered.

## Methods

`app.put` and `app.patch` take exactly `app.post`'s shapes, `app.delete` exactly `app.get`'s:

<!-- example: tests/test_methods.mojo#routing-methods -->
```mojo
from muntin import App, FromJson, Headers, Json, JsonValue, Request, Response, State
from muntin.testing import TestClient

# UserForm, User and Unauthorized: not defined here (see the line after the example).


@fieldwise_init
struct Rename(FromJson):
    var name: String

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        return Self(value["name"].string())


@fieldwise_init
struct Directory(Movable):
    var domain: String


def replace_user(id: Int, body: UserForm) -> String:  # `post`'s shapes; UserForm a FromBody
    return String("replaced ", id, " ", body.name)


def rename_user(
    users: State[Directory], id: Int, body: Json[Rename]
) -> Json[User]:                                          # User a ToJson
    return Json(User(id, body.value.name + "@" + users[].domain))


def remove_user(id: Int, headers: Headers) raises Unauthorized -> String:
    if not headers.get("authorization"):  # `get`'s shapes; Unauthorized a ToErrorResponse
        raise Unauthorized()
    return String("removed ", id)


def purge(req: Request) raises -> Response:  # raw: reads a DELETE body as text
    return Response.text("purged " + req.path + " [" + req.text() + "]")


var app = App()
app.put["/users/{id}"](replace_user)
app.patch["/users/{id}"](rename_user, State(Directory("example.com")))
app.delete["/users/{id}"](remove_user)
app.delete["/cache"](purge)
# PUT /users/7  "name=Ada"                  -> 200 "replaced 7 Ada"
# PUT /users/7  "Ada" or ""                 -> 400 "Bad Request"  (from_body raised; replace_user not called)
# PATCH /users/7  Content-Type: application/json  {"name":"bo"}
#   -> 200, Content-Type: application/json, {"id":7,"name":"bo@example.com"}
# PATCH /users/7  (no Content-Type)         -> 415 "Unsupported Media Type"
# DELETE /users/7  Authorization: t1        -> 200 "removed 7"
# DELETE /users/7  (no Authorization)       -> 401 "Unauthorized"
# DELETE /users/abc                         -> 400 "Bad Request"  (remove_user not called)
# DELETE /cache  "all"                      -> 200 "purged /cache [all]"
# POST /users/7, HEAD /users/7 (no get route here), OPTIONS /users/7, delete /users/7
#   -> 405 "Method Not Allowed", Allow: PUT, PATCH, DELETE
# GET /cache                                -> 405 "Method Not Allowed", Allow: DELETE

var client = TestClient(app)
_ = client.put("/users/7", "name=Ada")
var h = Headers()
h.add("Content-Type", "application/json")
_ = client.patch("/users/7", '{"name":"bo"}', headers=h^)
_ = client.delete("/users/7")                       # 401: no field sent
_ = app.handle(Request("DELETE", "/cache", "all"))  # a DELETE body: build the Request
```

Run by `tests/test_methods.mojo` (`test_dx_example`), which also defines the three types the example uses without defining: `UserForm`, the `name=` text body of [bodies](bodies.md#text-bodies-frombody) (`CreateUser` there, renamed); `User`, the `ToJson` type of [bodies](bodies.md#json-jsont) that writes `{"id":…,"name":…}`; and `Unauthorized`, the 401 `ToErrorResponse` of [headers](headers.md#reading-fields-in-a-handler). It checks every commented answer, sending `POST`, `HEAD` and `OPTIONS /users/7` through `App.handle` with the body `name=Ada`.

- Everything said about `post`'s shapes holds for `put` and `patch`, and about `get`'s for `delete`: route values, decoding and 400s, body steps, results and errors, in the same order. Diagnostics name the method (`a patch handler takes one request body, as its last parameter`).
- A typed `delete` handler takes no body (`constraint failed: a delete handler takes no request body`), and a body sent to it is not read. A raw `delete` handler receives the whole request, `req.body` included.
- Through Flare, a method with a lowercase letter (`delete`, `Get`) is answered 400 by Flare's HTTP/1.1 parser before `App.handle`; an unknown uppercase method (`FOO`) reaches `App.handle`.

### Bodyless `post`, `put` and `patch`

A `post`, `put` or `patch` handler whose parameters are only route values and at most one `Headers`, last, is bodyless: it takes `get`'s shapes and answers exactly as the same handler on `get` would.

<!-- example: tests/test_bodyless.mojo#routing-bodyless -->
```mojo
@fieldwise_init
struct Db(Movable):
    var name: String


def activate(id: Int) -> String:  # no body: the request's is not read
    return String("activated ", id)


def logout(headers: Headers) raises Unauthorized -> String:
    if not headers.get("authorization"):
        raise Unauthorized()
    return "bye"


def follow(db: State[Db], id: Int) -> String:
    return String(db[].name, " follows ", id)


var app = App()                       # its own App
app.post["/users/{id}/activate"](activate)
app.post["/logout"](logout)
app.put["/users/{id}/follow"](follow, State(Db("ada")))
# POST /users/7/activate  (no body, or any body App.handle receives) -> 200 "activated 7"
# POST /users/abc/activate                     -> 400 "Bad Request"
# POST /logout  Authorization: t1              -> 200 "bye"
# POST /logout  (no Authorization)             -> 401 "Unauthorized"
# PUT /users/7/follow                          -> 200 "ada follows 7"
# GET /users/7/activate                        -> 405, Allow: POST
```

Run by `tests/test_bodyless.mojo` (`test_dx_example`), which also defines `Unauthorized`, the 401 `ToErrorResponse` of [headers](headers.md#reading-fields-in-a-handler) (with its own empty `__init__` instead of `@fieldwise_init`). It sends `activate` the bodies `""` and `"anything"`.

- The body is not read: any body, bytes that are not UTF-8 and a JSON `Content-Type` change nothing, and Muntin chooses no status for it. A backend may still refuse a request before `App.handle` (through Flare, a body over the `Server`'s `max_body_bytes`). A handler that must refuse a body takes a body type that refuses it, or is raw.
- A shape with a body is not bodyless: a last parameter whose type has no Muntin kind is still `the handler's last parameter is the request body; its type must conform to FromBody or FromBytes`.
- A route with a body and a request with an empty body: the body rules apply to `""`.

## `HEAD`

A `get` route answers `HEAD`:

<!-- example: tests/test_head.mojo#routing-head -->
```mojo
from muntin import App, Request, Response
from muntin.testing import TestClient


def show_user(id: Int) -> String:
    return String("user ", id)


def report(req: Request) -> Response:  # raw: req.method is "GET" or "HEAD"
    return Response.text("report")     # the GET body for both


def drop(id: Int) -> String:
    return String("dropped ", id)


var app = App()                        # its own App
app.get["/users/{id}"](show_user)
app.get["/report"](report)
app.delete["/cache/{id}"](drop)
# HEAD /users/7   -> 200 "user 7" from App.handle, as GET /users/7; through Flare: 200, Content-Length: 6, no content
# HEAD /users/abc -> 400 "Bad Request" (show_user not called); through Flare: 400, Content-Length: 11, no content
# HEAD /report    -> report receives req.method == "HEAD": 200 "report"; through Flare: Content-Length: 6, no content
# HEAD /cache/1   -> 405 "Method Not Allowed", Allow: DELETE; through Flare: Content-Length: 18, no content
# head /users/7, OPTIONS /users/7 -> 405 "Method Not Allowed", Allow: GET, HEAD
# HEAD /missing   -> 404 "Not Found"

var head = TestClient(app).head("/users/7")  # = app.handle(Request("HEAD", "/users/7"))
# head.status == 200, head.text() == "user 7": the in-memory response keeps the body
```

Run by `tests/test_head.mojo` (`test_dx_example`), which checks each `HEAD` answer of `App.handle` against the `GET` answer and `TestClient.head`'s against `App.handle`'s. The "through Flare" parts are not checked on this `App`: `adapters/flare/test_localhost_roundtrip.mojo` (`test_headers_over_h2c_follow_the_same_rules`) checks the same rule on its own routes (a typed `/hello`, a raw `/report` with length 6, a route-value 400 with 11, a 405 on `/form` with 18), over HTTP/1.1 and cleartext HTTP/2.

- `HEAD` is answered by the first `GET` route whose path matches, with every step of `GET`. A typed handler cannot tell `HEAD` from `GET`. A raw `get` handler receives `req.method == "HEAD"` and must return the body it would give `GET`: the backend declares that body's length, so a shorter body sends a wrong `Content-Length`, which Muntin cannot check. Middleware is under the same rule. Only the exact token `HEAD` maps.
- `App.handle` keeps the body. A network backend sends the status and fields with no content and a `Content-Length` equal to the body's byte length, or none for 1xx, 204, 205 and 304. The Flare adapter applies this to every answer it sends for `HEAD`, its own 400, 431 and 500 included. For a `HEAD` 205 or 304, whose body the adapter has removed, Flare itself still writes `Content-Length: 0` over HTTP/1.1. The Flare adapter drops a handler's own `Content-Length`, as it does for every method; `App.handle` keeps it. Why: [M3-026](../history/decisions/m3-026-head-decision.md).
- `TestClient.head` returns `App.handle`'s answer unchanged, body included ([testing](testing.md)).
- Cost: every `HEAD` computes and converts the whole `GET` body.

## 405 `Method Not Allowed`

A request whose path a route matches, when no route on that path has its method, is answered 405 with an `Allow` field:

<!-- example: tests/test_method_not_allowed.mojo#routing-405 -->
```mojo
var app = App()                          # its own App
app.get["/users/me"](me)                 # def me() -> String
app.delete["/users/{id}"](delete_user)   # def delete_user(id: Int) -> String
app.get["/users/{id}"](get_user)         # def get_user(id: Int) -> String
app.put["/users/{id}"](update_user)      # def update_user(id: Int, body: Note) -> String
app.post["/hooks"](hook)                 # raw: def hook(req: Request) -> Response
# POST /users/7, OPTIONS /users/7, FOO /users/7 -> 405 "Method Not Allowed", Allow: DELETE, GET, HEAD, PUT
# POST /users/me  -> 405, Allow: GET, HEAD, DELETE, PUT  (/users/me and /users/{id} both match the path)
# POST /users/abc -> 405, Allow: DELETE, GET, HEAD, PUT  (nothing is decoded or converted to decide it)
# PUT /users/me   -> 400 "Bad Request"  (PUT selects /users/{id}; "me" is no Int)
# GET /hooks, HEAD /hooks -> 405, Allow: POST; through Flare, HEAD /hooks: Content-Length: 18, no content
# POST /users/7/x, POST /missing -> 404 "Not Found"
```

Run by `tests/test_method_not_allowed.mojo` (`test_dx_example`), which defines the handlers with the signatures in the comments (each also counts its calls) and `Note`, a `FromBody` that takes any text. The "through Flare" part is not checked on this `App`: `adapters/flare/test_localhost_roundtrip.mojo` (`test_headers_over_h2c_follow_the_same_rules`) checks a `HEAD` 405 with `Allow: POST` and `Content-Length: 18` on its own route `/form`.

- The answer is `Response.text("Method Not Allowed", status=405)` with one `Allow` field and no `Content-Type`. Nothing is decoded or converted and no handler runs.
- `Allow` lists the methods of the routes whose path matches, each once, in the order their first such route was registered, `HEAD` right after `GET`, joined by `, `. A method in `Allow` selects a route, which may still answer 400.
- Every method is answered alike: `OPTIONS`, unknown and lowercase methods are 405 on a path some route matches and 404 elsewhere. Muntin does not answer `OPTIONS` or a CORS preflight itself, and does not answer 501 ([M3-030](../history/decisions/m3-030-method-not-allowed-decision.md)).
- Middleware may replace or change a 405; the `Allow` on a 405 it builds or changes is the application's responsibility.

## Order of checks

On a typed route each step runs only if the previous one passed:

1. Method and path: 404, or 405 with `Allow`. Nothing decoded.
2. Path values, in order, decoded: a bad escape or bytes that are not UTF-8, 400.
3. Query values: one of the route's keys repeated anywhere in the query, 400; then each in order, a required key missing or its value empty, a bad escape or bytes that are not UTF-8, 400.
4. Route values converted, in order (an `Int` that does not parse, a `from_route_value` raise): 400. The first invalid value stops the rest.
5. `Json[T]` bodies: `Content-Type` 415, then the type's limit 413 (1 MiB unless `Json[T, limit=n]`).
6. Other bodies, bare or carried: the type's `max_bytes`, 413 (1 MiB when a `FromBody` type declares none; [body size limits](body-limits.md)).
7. `WithHeaders[B]` and `Headers` parameters: the field rebuild (the fixed 500, only for a field an in-memory `Headers` holds invalidly).
8. Text bodies: bytes that are not UTF-8, 400.
9. Body conversion (`from_body`, `from_json`, `from_bytes`): a raise is 400.
10. The handler: a raise is its error type's response or the fixed 500 ([errors](errors.md)).
11. The result, converted once ([responses](responses.md)).

A raw route runs only step 1, then the handler ([raw handlers](raw.md)). A route of a [guarded group](groups.md) runs its guard after step 3 (after step 1 for a raw route), and a 400 from steps 2 and 3 only once the guard has passed.

## Compile-time diagnostics

A handler whose parameter count an overload accepts but whose shape breaks a rule reports the rule as `constraint failed: <rule>`, under `function instantiation failed` at the enclosing function with the registration call in the next note. Messages name the registration's method. Besides those on the topic pages:

- `route declares a path parameter but the handler takes none` (or `... a query parameter ...`);
- `handler takes one Int parameter; route must declare exactly one path or query parameter` (`one String parameter`, `one route value`, `one Optional route value ...`, `two route values ...`, and on a body route `... and the request body; ...`);
- `a get handler takes no request body`, `a get handler takes at most two route values`, `a get handler takes one Headers, as its last parameter`;
- `a get handler's parameter is an Int or String route value, an Optional of one, a FromRouteValue type, the request Headers or, for a raw handler, the Request` (a `Float64` or `StaticString` parameter, for example);
- `a post handler takes one request body, as its last parameter`; `a post handler's parameter before the body is a route value: an Int, a String, an Optional of either or a FromRouteValue type`;
- `a raw get handler takes only the Request and returns Response`, `a raw post handler takes only the Request and returns Response`, `Request is the whole request, not a body; a raw handler takes only the Request and returns Response`;
- the `State` messages ([state](state.md)).

A call that no overload takes gets `no matching method in call to 'get'` (or the other method) with one note per candidate, eight per method: more than three request parameters, a `State` parameter that is `var`, `mut`, a plain value or not first, or a result that is neither `String`, `StaticString` nor `ToResponse` (`candidate not viable: violated constraint`, then the `where` clause, which contains `identical(R, StringSpan[ImmStaticOrigin])`). When the call does not let the compiler decide the clause, the error is `invalid call to '<method>': lacking evidence to prove correctness` instead: a result with a local's immutable origin, or a forwarding helper's generic result without a matching `where` (below).

### Typed function values and generic forwarding

- A plain `def` handler registers as declared, with borrowed (`id: Int`) or owned (`var id: Int`) parameters.
- An explicitly typed function value, or a helper parameter of function type, spells each request parameter `var` and the error type with `raises`: `def(var Int) thin raises Never -> String`. `def(Int) thin raises Never -> String`, or a type without `raises` (`def() thin -> String`), fails with `TODO: function type conversions between closures not supported yet`. A leading `State[S]` keeps its spelling. Raw: `def(var Request) thin raises Never -> Response`.
- A helper generic over request parameters (`h: def(var A) thin raises Never -> String`, `def(State[S], var A, var B)`) or over the error type (`def register[E: Deinitable](mut app: App, h: def() thin raises E -> String)`) forwards to the registration and registers as the plain handler would. A generic result needs its own `where` clause that is one branch of the registration's (`where R == String`, `where R == StaticString`, `where conforms_to(R, ToResponse)`) or the whole clause.
