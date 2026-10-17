# Route values

A route value is a handler parameter filled from a `{name}` path segment or a `{key}` query item of the route literal ([routing](routing.md#route-literals)). Binding is positional: the path placeholders left to right, then the query placeholders left to right, fill the route-value parameters in order. Names are compared only through `Param` and `RouteValues` records (below). Every invalid value is 400 `Bad Request` before the handler; the order of checks is in [routing](routing.md#order-of-checks). Each example below is its own `App`, except that the query-value example adds to the `Int` example's; the line after each names the test that runs it and what that test adds or changes.

## `Int` values

```mojo
def hello() -> String:
    return "hello"


def get_user(id: Int) -> String:
    return String(id)


var app = App()
app.get["/hello"](hello)              # () -> String and (Int) -> String share one App
app.get["/users/{id}"](get_user)      # same registration syntax
# GET /users/42  -> 200 "42"   (get_user received Int(42))
# GET /users/abc -> 400 "Bad Request"   (get_user not called)
# GET /users     -> 404 "Not Found"
```

Run by `tests/test_app.mojo`: `users_app` registers these routes, the next example's `/items?{limit}` and also `/users/{id}/posts`; `test_path_parameter_reaches_handler_as_int`, `test_invalid_int_is_bad_request` and `test_typed_route_does_not_match_other_paths` check the answers.

- An `Int` is an optional `-` followed by one or more ASCII digits, within `Int` range; leading zeros are allowed (`042` is 42). Anything else, including forms Mojo's `Int(String)` accepts (`+42`, ` 42`, `4_2`), is 400.
- The placeholder's name is not compared with the parameter's: `app.get["/users/{user}"](get_user)` registers.

## Query values

```mojo
def list_items(limit: Int) -> String:
    return "items " + String(limit)


app.get["/items?{limit}"](list_items)    # the literal names the query key
# GET /items?limit=10          -> 200 "items 10"
# GET /items?limit=010         -> 200 "items 10"  (list_items received Int(10))
# GET /items?other=z&limit=10  -> 200 "items 10"  (other keys are ignored)
# GET /items, /items?limit=abc, /items?limit=1&limit=2 -> 400 "Bad Request" (list_items not called)
# GET /hello?x=1               -> 200 "hello"     (no-query routes ignore the query)
```

Registered on the `Int` example's `App` (`/hello` is its route). Run by `tests/test_app.mojo` on `users_app` (above): `test_query_parameter_reaches_handler_as_int`, `test_unrelated_query_keys_are_ignored`, `test_missing_query_parameter_is_bad_request`, `test_invalid_query_value_is_bad_request`, `test_duplicate_query_key_is_bad_request` and `test_route_matching_ignores_the_query`.

- The key is written in the literal because Mojo 1.1.0 cannot reflect a function's parameter names.
- The request query: pairs separated by `&`; key and value split at the first `=`; a pair without `=` has an empty value; empty pairs are skipped. Keys compare byte for byte, case-sensitively, and are never decoded (`lim%69t=1` does not match `limit`).
- A missing key, a repeated key (even with equal values) or an empty value is 400. An `Optional` value is `None` instead when missing or empty (below).
- The query takes no part in route selection: with `/items?{limit}` registered, `GET /items` matches it and is 400.

## `String` values and decoding

```mojo
def profile(name: String) -> String:
    return "profile " + name


def search(q: String) -> String:
    return "results for " + q


var app = App()                       # its own App: on the one above, /users/{name} after /users/{id} aborts
app.get["/users/{name}"](profile)
# GET /users/alice        -> 200 "profile alice"
# GET /users/J%C3%B6rg    -> 200 "profile Jörg"
# GET /users/a+b          -> 200 "profile a+b"     (`+` is literal in a path)
# GET /users/%zz, /users/%FF -> 400 "Bad Request"  (bad escape; not UTF-8)
app.get["/search?{q}"](search)
# GET /search?q=mojo+lang -> 200 "results for mojo lang"
# GET /search?q=a%2Bb     -> 200 "results for a+b"
# GET /search, /search?q=, /search?q=1&q=2 -> 400 "Bad Request"
app.get["/items?{limit}"](list_items)  # list_items as above
# GET /items?limit=%31%30 -> 200 "items 10"
```

Run by `tests/test_string_route_values.mojo` (`test_dx_examples`, on `_dx_app`), which also defines `list_items` as the query example does. The abort the first comment names is a repeated path ([route conflicts](routing.md#route-conflicts)).

### Decoding

- A route value is percent-decoded once, when it is captured, then converted. The decoding belongs to the capture, not the type: an `Int` and a `String` on one route see the same text. `/users/%2541` gives a `String` `"%41"`.
- Path value: the matched segment, with each `%` and two hex digits (either case) replaced by that byte; `+` is literal. `%2F` decodes to `/` inside the value and never splits a segment. Nothing is normalized: `..` and `%2E%2E` are the value `".."`.
- Query value: `+` becomes a space, then the same percent-decoding (`?q=a+b%2B` is `"a b+"`).
- Invalid, 400: an empty value, a `%` not followed by two hex digits, and decoded bytes that are not UTF-8 (`%FF`, `%C3`). Anything else that decodes to UTF-8 is a value, NUL and control characters included. **Decoding validates the encoding, not safety**: a handler that passes a route value to a filesystem, a C API, a database or an interpreter validates what that destination requires.
- An `Int` parses the decoded text (`%34%32` is 42; `%2B1` is still 400).
- This is not a form parser. Only the `+` rule comes from `application/x-www-form-urlencoded`. Unlike the WHATWG parser, Muntin answers 400 to `%zz` and to bytes that are not UTF-8 instead of keeping or replacing them, does not decode keys, and answers 400 to `?q=` and duplicates.
- Raw handlers and `Request` are never decoded: an application that must tell `%2F` from `/` uses a [raw handler](raw.md).

### `String` rules

- Only `String` itself is a route value: `StaticString`, `StringSlice` and other types are not (an application type is one through `FromRouteValue`, below). A `String` is never the request body: `def(String)` on `app.post` is a bodyless handler with one route value.
- The handler may declare `name: String` or `var name: String`; `mut name: String` matches no overload.

## Two route values

A handler takes up to two bare route values, on every method:

```mojo
from muntin import (
    App,
    FromJson,
    Headers,
    Json,
    JsonValue,
    JsonWriter,
    Response,
    ToErrorResponse,
    ToJson,
)


@fieldwise_init
struct Edit(FromJson):
    var title: String

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        return Self(value["title"].string())


@fieldwise_init
struct Post(ToJson):
    var uid: Int
    var pid: Int
    var title: String

    def write_json(self, mut out: JsonWriter) raises:
        out.begin_object()
        out.name("uid")
        out.int(self.uid)
        out.name("pid")
        out.int(self.pid)
        out.name("title")
        out.string(self.title)
        out.end_object()


@fieldwise_init
struct Unauthorized(ToErrorResponse):
    def to_error_response(deinit self) -> Response:
        return Response.text("Unauthorized", status=401)


def post_of(uid: Int, pid: Int) -> String:
    return String("post ", pid, " of user ", uid)


def user_fields(id: Int, fields: String) -> String:
    return String("user ", id, ": ", fields)


def search(q: String, limit: Int) -> String:
    return String(limit, " results for ", q)


def edit_post(uid: Int, pid: Int, body: Json[Edit]) -> Json[Post]:
    return Json(Post(uid, pid, body.value.title))


def remove_post(
    uid: Int, pid: Int, headers: Headers
) raises Unauthorized -> String:
    if not headers.get("authorization"):
        raise Unauthorized()
    return String("removed post ", pid, " of user ", uid)


var app = App()                       # its own App
app.get["/users/{uid}/posts/{pid}"](post_of)
app.get["/users/{id}?{fields}"](user_fields)
app.get["/search?{q}&{limit}"](search)
app.patch["/users/{uid}/posts/{pid}"](edit_post)
app.delete["/users/{uid}/posts/{pid}"](remove_post)
# GET /users/1/posts/2            -> 200 "post 2 of user 1"
# GET /users/1?fields=name+email  -> 200 "user 1: name email"
# GET /search?limit=5&q=mojo      -> 200 "5 results for mojo"   (the literal's order, not the request's)
# GET /users/1/posts/x, /search?q=mojo, /search?q=a&q=b&limit=5 -> 400 "Bad Request"  (handler not called)
# PATCH /users/1/posts/2  Content-Type: application/json  {"title":"Hi"}
#   -> 200, Content-Type: application/json, {"uid":1,"pid":2,"title":"Hi"}
# PATCH /users/1/posts/x  (no Content-Type)   -> 400 "Bad Request"  (the value answers before the body's 415)
# DELETE /users/1/posts/2  Authorization: t1  -> 200 "removed post 2 of user 1"
# DELETE /users/1/posts/2  (no Authorization) -> 401 "Unauthorized"
```

Run by `tests/test_route_values.mojo` (`test_dx_examples`, on `_dx_app`), which does not check the `Content-Type` of the `PATCH` answer and also checks that the same `PATCH` with a valid path and no `Content-Type` is 415. `test_swapped_names_bind_by_position` runs the swapped `post_of` of the bullets below, as `post_of_swapped`.

- `V` may be any route-value type, in any combination. The literal declares exactly two placeholders: two segments, two query items, or one of each. The request's query order does not matter.
- **Order is not checked for bare values.** Two values of one type declared in the other order compile and receive each other's values: `def post_of(pid: Int, uid: Int)` on `/users/{uid}/posts/{pid}` gets `pid == 1` for `/users/1/posts/2`. Declare both as `Param`s (below) to have the names checked ([why](../history/decisions/m3-022-several-route-values-decision.md)).
- Three or more values are one `RouteValues` record (below); three bare values are `constraint failed: a get handler takes at most two route values` (or the method's).
- Errors: `handler takes two route values; route must declare exactly two path or query parameters` (`... and the request body; ...` on a body route), whatever the values' types.

## Named route values (`Param`)

`Param["name", T]` names the placeholder a value binds; the registration checks the name at compile time. It is opt-in.

**`Param` checks the name written in its type annotation, not the handler's variable name.** Binding stays by position.

```mojo
from muntin import App, Param


def post_of(uid: Int, pid: Int) -> String:              # bare: bound by position, not checked
    return String("post ", pid, " of user ", uid)


def checked_post_of(uid: Param["uid", Int], pid: Param["pid", Int]) -> String:
    return String("post ", pid.value, " of user ", uid.value)


def make_app() -> App:
    var app = App()
    app.get["/users/{uid}/posts/{pid}"](post_of)
    app.get["/checked/{uid}/posts/{pid}"](checked_post_of)
    return app^
# GET /users/1/posts/2, /checked/1/posts/2 -> 200 "post 2 of user 1"
# GET /checked/1/posts/x                   -> 400 "Bad Request"
```

Run by `tests/test_named_values.mojo` (`test_dx_example`), which imports `post_of`, `checked_post_of` and `make_app` from `tests/named_value_handlers.mojo`, where they are written as here (see the crash below).

Intentionally does not compile:

```mojo
def wrong(pid: Param["pid", Int], uid: Param["uid", Int]) -> String: ...
app.get["/users/{uid}/posts/{pid}"](wrong)
# compile error: route value 1 is Param["pid"] but binds {uid}; route values bind the
#   path parameters left to right, then the query parameters

def mixed(uid: Param["uid", Int], pid: Int) -> String: ...
app.get["/users/{uid}/posts/{pid}"](mixed)
# compile error: handler takes two route values and only one is a Param; declare both
#   as Param, each named after the placeholder it binds, or neither
```

Checked by `tests/named_values_api_fail/get_swapped_names.mojo` and `get_mixed_values.mojo`, which `scripts/check.sh` builds and requires to fail with `constraint failed: ` and these messages. There each handler is named `post_of` and has a body.

- Checked: each `Param`'s name equals the placeholder at its position, on every method, stateless and stateful. Of two values, both or neither are `Param`s; a lone value may be either.
- Not checked: the variable's own name (`pid: Param["uid", Int]` holds the user's id), and two placeholders with one name (`/x/{a}/{a}`), which bind by position.
- `Param[name, T]` holds a `T` that is `Int`, `String`, `Optional[Int]`, `Optional[String]` or a `FromRouteValue` type, read as `uid.value`; it follows every rule of a bare `T`. `Param["x", Float64]` or a `Param` in a `Param` gets the method's "parameter is an Int or String route value ..." message.
- The name rules run after every other registration rule and before the repeated query key (`route declares a query parameter twice`), so a shape that breaks another rule reports that rule whether or not its values are named.
- Mojo 1.1.0 crashes (a compiler segmentation fault) when a module that discovers its tests with `TestSuite.discover_tests[__functions_in_module()]()` also defines a function with a `Param` parameter. Keep such handlers in another module and import them.

## Optional query values

An `Optional[Int]` or `Optional[String]` parameter is a query value that may be absent; the handler supplies any default:

```mojo
from muntin import App, Headers


def list_items(limit: Optional[Int]) -> String:
    return "items " + String(limit.or_else(20))


def search(q: String, sort: Optional[String]) -> String:
    return "results for " + q + " by " + sort.or_else("relevance")


def posts(uid: Int, limit: Optional[Int], headers: Headers) -> String:
    return String("user ", uid, ": ", limit.or_else(20), " posts")


def tag_user(tag: Optional[String], body: CreateUser) -> String:   # CreateUser: see below
    return "created " + body.name + " tagged " + tag.or_else("none")


var app = App()                       # its own App
app.get["/items?{limit}"](list_items)
app.get["/search?{q}&{sort}"](search)
app.get["/users/{uid}/posts?{limit}"](posts)
app.post["/users?{tag}"](tag_user)
# GET /items, /items?limit=, /items?limit    -> 200 "items 20"   (limit is None)
# GET /items?limit=5, /items?limit=%35       -> 200 "items 5"
# GET /items?limit=x, /items?limit=1&limit=2 -> 400 "Bad Request" (list_items not called)
# GET /search?q=mojo                         -> 200 "results for mojo by relevance"
# GET /search?sort=date&q=mojo               -> 200 "results for mojo by date"
# GET /search?sort=date                      -> 400 "Bad Request"  (q is required)
# GET /users/1/posts, /users/1/posts?limit=5 -> 200 "user 1: 20 posts", "user 1: 5 posts"
# POST /users  "name=Ada"                    -> 200 "created Ada tagged none"
# POST /users?tag=a+b  "name=Ada"            -> 200 "created Ada tagged a b"
```

Run by `tests/test_optional_values.mojo` (`test_dx_examples`, on `_dx_app`), which also defines `CreateUser`, the `name=` text body of [bodies](bodies.md#text-bodies-frombody), as written there, and also checks `GET /items?%6Cimit=5` (keys are not decoded: 200 "items 20").

- An optional value binds a `{key}` query placeholder only; one at a path position is a compile error (`an Optional route value binds a query parameter; route values bind the path parameters first, then the query parameters`, or alone `handler takes one Optional route value; route must declare exactly one query parameter and no path parameter`).
- Absent and empty are one case: a missing key, `limit=` and `limit` are all `None`; Muntin never passes `Some("")`. A route that must tell `?q=` from no `q` uses a raw handler. `limit=+` is a present space.
- A present value keeps every rule of a required one: a bad escape or an `Int` that does not parse is 400, not `None`; a repeated key is 400.
- A parameter default (`limit: Int = 20`) does not travel with a function value on Mojo 1.1.0: it registers as a required `Int` without a diagnostic. Use `Optional` and `or_else` ([why](../history/decisions/m3-024-optional-query-values-decision.md)).
- Only `Optional[Int]` and `Optional[String]` are optional values. `Optional[Optional[Int]]`, `Optional[Float64]` and an `Optional` of a `FromRouteValue` type are parameters of no kind.
- A typed function value spells it `var Optional[Int]`.

## Application route values (`FromRouteValue`)

An application type conforming to `FromRouteValue` is a route value; it decides how the text reads:

```mojo
from muntin import App, FromRouteValue


struct UserId(FromRouteValue, Movable):
    var value: Int

    def __init__(out self, value: Int):
        self.value = value

    @staticmethod
    def from_route_value(value: String) raises -> Self:
        if not value.startswith("u"):
            raise Error("a user id is u and a number")
        return Self(Int(value[byte=1:]))


struct Order(FromRouteValue, Movable):
    var newest_first: Bool

    def __init__(out self, newest_first: Bool):
        self.newest_first = newest_first

    @staticmethod
    def from_route_value(value: String) raises -> Self:
        if value == "new":
            return Self(True)
        if value == "old":
            return Self(False)
        raise Error("order is new or old")


def get_user(id: UserId) -> String:
    return "user " + String(id.value)


def list_posts(id: UserId, order: Order) -> String:
    var by = "newest" if order.newest_first else "oldest"
    return "posts of user " + String(id.value) + ", " + by + " first"


def make_app() raises -> App:
    var app = App()
    app.get["/users/{id}"](get_user)
    app.get["/users/{id}/posts?{order}"](list_posts)
    return app^
# GET /users/u42                  -> 200 "user 42"
# GET /users/%7542                -> 200 "user 42"   (decoded before from_route_value)
# GET /users/42                   -> 400 "Bad Request"  (from_route_value raised; get_user not called)
# GET /users/u42/posts?order=new  -> 200 "posts of user 42, newest first"
# GET /users/u42/posts?order=top, /users/u42/posts -> 400 "Bad Request"
```

Run by `tests/test_app_route_values.mojo` (`test_dx_example`), which imports `UserId`, `Order`, `get_user`, `list_posts` and `make_app` from `tests/app_route_value_handlers.mojo`, where they are written as here; `GET /users/%7542` is checked by `test_value_is_decoded_once_and_never_empty`.

- `from_route_value` receives the text a `String` value would: decoded, never empty. **Any raise is 400 with the error's text dropped**, whatever raised, so keep it to reading the text; do work that can fail for other reasons (a lookup) in the handler, where a raise is a 500 or the error's own response.
- It goes wherever a required `String` value goes: once or twice, on every method, stateless or stateful, in a `Param`, as a record field. Values convert left to right, then the body; a raise stops the rest.
- The type conforms in its own module and may be move-only.
- A type is a route value or a body, not both: one that also conforms to `FromBody` or `FromBytes` is `a parameter's type conforms to FromRouteValue and to FromBody or FromBytes; a type is a route value or a body, not both`.
- Standard types other than `Int` and `String` (`Bool`, `Float64`) cannot be route values: an application cannot conform them ([why](../history/decisions/m3-054-application-route-value-types-decision.md)).

## Route-value records

A struct conforming to `RouteValues` is one parameter carrying every route value of its route, one field per placeholder, each named after the placeholder it binds. It is how a handler takes three or more values:

```mojo
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
```

Run by `tests/test_route_records.mojo` (`test_dx_example`), which declares the types in another order, sends the body `not json` with the 400 and 415 requests, checks only their statuses, and also checks that `PATCH .../tasks/0` is the fixed 500 (`update_task` raised) and that `App.handle` answers a `PATCH` alike.

Intentionally does not compile:

```mojo
@fieldwise_init
struct Swapped(RouteValues):
    var project_id: Int
    var org_id: Int
    var task_id: Int

def wrong(at: Swapped) -> String: ...
app.get["/o/{org_id}/p/{project_id}/t/{task_id}"](wrong)
# compile error: field 1 of the RouteValues record is project_id but binds {org_id}; route
#   values bind the path parameters left to right, then the query parameters

app.get["/o/{org_id}/p/{project_id}"](get_task)
# compile error: the RouteValues record has 3 fields but the route declares 2 path and
#   query parameters; a record has one field per parameter
```

Checked by `tests/route_records_api_fail/get_name.mojo` and `get_count.mojo` (and their `post_`, `state_delete_` and `state_patch_` variants), which `scripts/check.sh` builds and requires to fail with `constraint failed: ` and these messages. There the handler is `h`, which returns `String`, and `get_count.mojo` defines its own `TaskAt`.

- **Muntin never calls the record's `__init__`.** It initializes the fields directly, so neither the record's initializer nor a relation across fields (`start_id <= end_id`) is checked. A record is a transport type for its route's values: validate one value in its field's type (a `FromRouteValue`), and build a domain type that relates fields in the handler. A record that declares its own `__init__` is not refused (Mojo 1.1.0 reflects fields, not initializers; [why](../history/decisions/m3-061-route-value-records-decision.md)). Its destructor runs once for a completed record and never for one whose conversion failed, so it must not rely on anything only `__init__` establishes.
- Fields: one per placeholder, in the literal's order, each named after its placeholder (`{org-id}` binds `` var `org-id`: Int ``). Each is a bare route value (`Int`, `String`, a `FromRouteValue` type, or an `Optional` at a query placeholder). A record may be generic.
- Shapes: a record takes the shapes of one bare value (`def(P)`, `def(P, Headers)`, `def(P, B)`, each after any `State`), and is the handler's only route value, its first parameter after any `State`. Not accepted: a record beside a bare value or another record, in a raw handler, a `Param` or a `WithHeaders`.
- Fields convert in field order; the first invalid one is 400 and nothing after it, the body included, is converted.
- Routes no record takes: a literal that names a placeholder twice, and a query key containing a backquote; such a route takes at most two bare values.
- Errors, each `constraint failed: ...`: `a handler takes at most one RouteValues record, as its first parameter after any State`; `a handler that takes a RouteValues record takes no other route value; the record has a field for each`; `the RouteValues record has no field; ...`; `field 2 of the RouteValues record, ratio, is not a bare route value: ...`; `field 2 of the RouteValues record, project_id, conforms to FromRouteValue and to FromBody or FromBytes; ...`; the count and name messages above; `the route declares the parameter {id} twice; ...`; `field 1 of the RouteValues record, org_id, is an Optional but binds the path parameter {org_id}; an Optional field binds a query parameter`; and for a record that is also a route value or body, `a parameter's type conforms to RouteValues and to FromRouteValue, FromBody or FromBytes; a route-value record is none of them`.
