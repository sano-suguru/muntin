# Guarded groups

A `Group` holds routes behind one guard: a function that runs before each of them, with start-up values, and can refuse the request or hand the handler a typed value such as the authenticated user ([M3-080](../history/decisions/m3-080-guarded-routes-and-request-context-decision.md)). The group's routes are moved into an `App` with `app.mount(group^)`. Each example below is its own `App`; the line after it names the test that runs it and what that test adds or changes.

<!-- example: tests/test_reference_examples.mojo#groups-notes groups_app=make_app -->
```mojo
from muntin import App, Group, Headers, Response, State, ToErrorResponse


struct Accounts(Movable):                 # built once, at start-up
    var tokens: Dict[String, String]      # token -> user name

    def __init__(out self, var tokens: Dict[String, String]):
        self.tokens = tokens^


@fieldwise_init
struct Member(Movable):                   # the context type: owns its data
    var name: String


@fieldwise_init
struct Unauthorized(ToErrorResponse):
    def to_error_response(deinit self) -> Response:
        var response = Response.text("Unauthorized", status=401)
        try:
            response.headers.add("WWW-Authenticate", "Bearer")
        except:
            pass
        return response^


def authenticate(
    accounts: State[Accounts], headers: Headers
) raises Unauthorized -> Member:
    var field = headers.get("authorization").or_else("")
    if field.startswith("Bearer "):
        var name = accounts[].tokens.get(String(field[byte=7:]))
        if name:
            return Member(name.value())
    raise Unauthorized()


def me(member: Member) -> String:                   # the context first
    return "me " + member.name


def note(member: Member, id: Int) -> String:        # then the usual parameters
    return member.name + "'s note " + String(id)


def count(accounts: State[Accounts]) -> String:     # guarded, without the context
    return String(len(accounts[].tokens))


def version() -> String:
    return "1.0"


def make_app() -> App:
    var tokens = Dict[String, String]()
    tokens["t1"] = "ada"
    var accounts = State(Accounts(tokens^))
    var app = App()
    app.get["/version"](version)                     # not guarded
    var members = Group(authenticate, accounts)      # the guard and its state
    members.get["/me"](me)
    members.get["/notes/{id}"](note)
    members.get["/count"](count, accounts)
    app.mount(members^)
    return app^
# GET /version                              -> 200 "1.0"  (authenticate not called)
# GET /me        Authorization: Bearer t1   -> 200 "me ada"
# GET /me                                   -> 401 "Unauthorized", WWW-Authenticate: Bearer
# GET /notes/7   Authorization: Bearer t1   -> 200 "ada's note 7"
# GET /notes/x   Authorization: Bearer t1   -> 400 "Bad Request"  (note not called)
# GET /notes/x                              -> 401  (the guard answers first)
# GET /count     Authorization: Bearer t1   -> 200 "1"
```

Run by `tests/test_reference_examples.mojo` (`test_groups_notes`), with `make_app` named `groups_app`: the test sends the requests above to the `App` it returns, and one with an unknown token (401).

## Rules

- **The guard** is `def(state: State[S], headers: Headers) -> C`, non-raising, `raises` or `raises T`, and `Group(guard, state)` takes it with its state. `S` need not be the handlers' state type. The group keeps a copy of the `State` handle and each of its routes another; the value is dropped once, after the last ([state](state.md#rules)).
- **Registration** on a group is the `App`'s: the same five methods, overloads and rules ([routing](routing.md#registering-a-route)). A handler whose first request parameter (after `State[S]`, if any) has the guard's type `C` receives the value the guard returned, moved; a raw handler takes `(C, Request)` or `(State[S], C, Request)`. The context counts as one of the three request parameters. A handler without it is guarded all the same, and the value is dropped.
- **Mounting:** `app.mount(group^)` moves the group's routes into the `App` in their registration order, each checked for a conflict as its own registration on the `App` at that point would be ([routing](routing.md#route-conflicts)); a conflict aborts at `mount`. A group answers nothing until it is mounted: `TestClient`, like `Server`, takes only an `App`. Groups do not nest.
- **Order of checks** on a guarded route: 404 or 405, which never call the guard; the route values gathered and decoded; the guard; a 400 from that decoding, held until the guard has passed; then the typed route's remaining steps ([routing](routing.md#order-of-checks)) and the handler. So the guard answers before any type conversion and before the body is read: a request it refuses gets its refusal even when its route values, `Content-Type` or body are bad. `HEAD` runs the guard as `GET` does.
- **What the guard sees:** the request's header fields, rebuilt into a fresh `Headers` with every field in order, as a `Headers` parameter receives them ([headers](headers.md)). Not the method, the path, the route values or the body.
- **Errors:** a raise from the guard is answered as a handler's ([errors](errors.md)): its declared error type's `to_error_response()` when it conforms to `ToErrorResponse`, otherwise the fixed 500 with a `Failure.HANDLER` report. A value the guard made before it raised is dropped.
- **Middleware** registered on the `App` wraps the mounted routes like any other; a group takes none ([middleware](middleware.md)).
- **The context type** owns its data: the rule `State` applies, by the type's printed name, refuses one that shows an origin or a parameter pack, `StaticString` included, with its known gap ([state](state.md#which-state-types-compile)); wrap such a value in a struct of the application's own. It is no request parameter kind (a route value, a record, a body, `Headers`, `Request`, `State`).
- **Cost:** each request a guarded route selects copies every header field twice for the guard's `Headers`, whether or not the guard reads it, and each route value once more; the guard runs once per request.

## Compile-time diagnostics

| Mistake | Message |
|---|---|
| The context after another request parameter, or twice | `a Group's handler takes the group's context type once, as its first request parameter (after State, if any): <C>` |
| A stateful handler registered without its state | the `State` rule's message, as on an `App` ([state](state.md)) |
| `Group[S, E, C]()`, without a guard | `a Group is built from its guard and the guard's state` |
| A context type on an `App`'s route, or another type than the guard's in a group | the rule for a parameter of no kind, `a get handler's parameter is ...` ([routing](routing.md#compile-time-diagnostics)) |
| A context type whose name shows an origin or a pack | `a Group's context type must own its data; its name shows an origin or a parameter pack: <C>` |
| A context type that is a request parameter kind (`Int`, for example) | `a Group's context type must not be a request slot kind (a route value, a body, Headers, Request or State): <C>` |
| `group.use(f)` | `a Group takes no middleware: register it on the App` |
| `app.mount(App())`; `group.mount(other^)` | `mount takes a Group`; `mount: a Group mounts no Group` |
| `group.handle(request)` | `a Group is mounted, not served` |
| `TestClient(group)` | `no matching function in initialization`, the note naming `_App[...]` types |

Pinned by `tests/group_api_fail`; the conflict at `mount` by `tests/route_conflict_abort/mounted_group.mojo`. Every rule above is run by `tests/test_group.mojo`, under `SANITIZE=address` in CI.
