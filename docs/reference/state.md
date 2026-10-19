# Application state

A handler receives long-lived application data as `State[S]`, passed as the registration's second argument. There are no globals: Mojo 1.1.0 has no module-level variables and handlers cannot capture. Each example below is its own `App`; the line after it names the test that runs it and what that test adds or changes.

<!-- example: tests/test_state_examples.mojo#state state_app=make_app -->
```mojo
from muntin import App, State


struct Users(Movable):
    var names: List[String]

    def __init__(out self, var names: List[String]):
        self.names = names^

    def get(self, id: Int) raises NotFound -> String:
        if id < 0 or id >= len(self.names):
            raise NotFound(id)
        return self.names[id]


def load_names() -> List[String]:
    var names = List[String]()
    names.append("ada")
    return names^


def hello() -> String:
    return "hello"


def get_user(users: State[Users], id: Int) raises NotFound -> User:
    return User(id, users[].get(id))       # read-only access to the shared value


def make_app() -> App:
    var users = State(Users(load_names()))   # the application builds the value once
    var app = App()                          # App stays non-generic
    app.get["/hello"](hello)                 # stateless handlers: unchanged
    app.get["/users/{id}"](get_user, users)  # the state is the registration's second argument
    return app^
# GET /hello    -> 200 "hello"
# GET /users/0  -> get_user(users, 0) -> User(0, "ada").to_response() -> 200 "0:ada"
# GET /users/1  -> NotFound(1).to_error_response() -> 404 "no user 1"
# GET /users/x  -> 400 "Bad Request"   (get_user not called)
```

Run by `tests/test_state_examples.mojo` (`test_state`), with `make_app` named `state_app`: the test sends the requests to the `App` it returns. That module defines the two types the example takes from other pages: `NotFound`, the `ToErrorResponse` type of [errors](errors.md#application-error-responses-toerrorresponse), and `User`, a [`ToResponse`](responses.md#toresponse) type holding `id` and `name` whose `to_response` is `Response.text(String(self.id) + ":" + self.name)` (the responses page's `UserText` is the same type with a space instead of `:`).

## Rules

- **Which parameter:** a handler takes state exactly when its registration passes a `State[S]`. Its first parameter is then `State[S]` (the same `S`), and the rest is one of the stateless shapes, bound as before: `def(State[Users], Int, CreateUser)` on `post` is state, route value, body. Request handling is the stateless twin's.
- **Ownership:** `State(value)` takes the value. `State` is a shared handle: the application keeps its own, each registration keeps a copy, and the value is destroyed when the last handle goes. A request borrows the route's handle and copies or allocates nothing.
- **Read-only:** `users[]` is read-only through every handle. A value that must change while serving keeps that mutability in its own fields, under its own rules. A reference from `users[]` lives no longer than its handle (`use of invalidated interior reference` after the handle is reassigned or moved).
- **The state may borrow nothing.** `S` must own its data: `State(value)` does not compile when `S`'s name shows an origin or a parameter pack anywhere (`View[o]`, a closure that captures by reference): `constraint failed: State takes a value that owns its data; this type's name shows an origin or a parameter pack ({}), so it may borrow a value the App outlives: <the type>` ([M3-074](../history/decisions/m3-074-state-borrowing-decision.md)). The rule reads the type's name, so it also refuses some owned types: a static origin (`StaticString`, `Optional[StaticString]`) and packs (`Tuple`, `Variant`, `List[Tuple[...]]`). Move such a value into a field of the application's own struct (`struct Pair: var value: Tuple[Int, String]`, then `State(Pair(...))`). A type that hides `AnyOrigin` behind a trait's associated type still registers; Muntin claims no memory safety for values built with `AnyOrigin`. [Which state types compile](#which-state-types-compile) lists each case.
- **Several values:** one `State` per handler; several values are the fields of one state type. Different routes may take different state types.
- **Threads:** with the Flare adapter's `Server`, an `App` and its `State` values stay on one thread for the `App`'s life: `serve(app)` serves on the calling thread, and `serve[make](workers=n)` builds one `App`, with its own `State` values, per worker on its thread. A counter in one worker counts that worker's requests; state every worker must see belongs outside the process. That is the adapter's behavior, not Muntin's: another backend may call an `App` from several threads in turn, and then `State` values must be safe to use on another thread ([testing](testing.md#the-backend-seam)).

State goes first so the body stays last. Access is `state[]` because a struct cannot forward field access.

## Which state types compile

The rule reads the type's full name, not who owns the data: it refuses `State(value)` exactly when that name, which the refusal prints, contains `{}`. The table lists only the types the named tests and fixtures try; read any other type by its name.

| `S`, the type of `State(value)`'s value | Compiles | Pinned by |
|---|---|---|
| `List[String]`, `Dict[String, Int]`, `ArcPointer[Users]` (`Users`, a struct of owned fields) | yes | `tests/test_state.mojo` (`test_owned_state_types_register`) |
| A struct with a `StaticString` field (`Label`) | yes | the same test |
| A struct with an `Int` parameter (`Sized[3]`), a struct value with a field as a parameter (`Tuned[Mode.FAST]`), or a function as a parameter (`Computed[five]`) | yes | the same test |
| A non-generic struct with a `Tuple[Int, String]` or `Variant[Int, String]` field (`Pair`, `Choice`) | yes | `tests/test_state.mojo` (`test_owned_values_in_a_wrapper_register`) |
| An origin parameter: a view of a local, mutable or not, `ImmutAnyOrigin`, `StaticString` | no | `tests/state_fail/state_origin_*.mojo` |
| An origin or a pack inside a type argument, owned or not: `Box[View[o]]`, `Tuple[View[o]]`, `Variant[View[o]]`, `ArcPointer[StaticString]`, `Box[Tuple[Int, String]]` | no | those fixtures and `tests/state_fail/state_pack_in_type_argument.mojo` |
| A closure that captures by reference | no | `tests/state_fail/state_origin_closure.mojo` |
| A pack as the whole state, even an owned one: `Tuple(1, String("a"))` | no | `tests/state_fail/state_pack_tuple.mojo` |
| A struct value with no fields as a parameter (`Config[Flag()]`, printed `Config[{}]`) | no | `tests/state_fail/state_empty_struct_parameter.mojo` |
| A pointer built with `AnyOrigin` behind a trait's associated type, alone or inside an `Optional`, a `List` or a `Tuple` field | **yes, and it reads freed memory** | `tests/state_known_gaps/state_any_origin_*.mojo` |

So the migration for a refused owned value is a field whose type is written out in a non-generic struct of the application's own (`Pair`), not a generic wrapper (`Box[Tuple[...]]`).

The rule is a measure for the current toolchain, not a lasting guarantee and not memory safety: it searches the name as Mojo 1.1.0 prints it (`reflect[S].name()`) for `{}`, the text of every origin, of a parameter pack and of a struct value with no fields, an undocumented format, because Mojo has no origin bound that generic code can state. The last row shows a state that passes it and reads freed memory. If Mojo stops printing an origin that way, the refused fixtures above build and `./scripts/check.sh` fails; the conditions for replacing the rule are [M3-074](../history/decisions/m3-074-state-borrowing-decision.md)'s "Revisit when".

## `post`, `put` and `patch`

<!-- example: tests/test_state_examples.mojo#state-post post_app=make_app -->
```mojo
def update_user(users: State[Users], id: Int, body: CreateUser) raises NotFound -> User:
    return User(id, users[].get(id) + " as " + body.name)


def make_app() -> App:
    var names = List[String]()
    names.append("ada")
    names.append("bob")
    var users = State(Users(names^))
    var app = App()
    app.post["/users/{id}"](update_user, users)  # state, route value, body
    return app^
# POST /users/1 "name=bo" -> update_user(users, 1, CreateUser("bo")) -> User(1, "bob as bo")
# POST /users/9 "name=bo" -> NotFound(9).to_error_response() -> 404 "no user 9"
# POST /users/x "name=bo" -> 400 "Bad Request"   (from_body and update_user not called)
```

The imports, `Users`, `User` and `NotFound` are the first example's; `CreateUser` is the `name=` text body of [bodies](bodies.md#text-bodies-frombody). Run by `tests/test_state_examples.mojo` (`test_state_post`), with `make_app` named `post_app`, as the first example is. That neither `from_body` nor the handler runs for an invalid route value is checked by `tests/test_state_post.mojo` (`test_bad_route_value_is_400_before_the_body`).

## Raw handlers

<!-- example: tests/test_state_examples.mojo#state-raw raw_app=make_app -->
```mojo
from muntin import App, Request, Response, State


@fieldwise_init
struct WebhookKeys(Movable):
    var secret: String


def webhook(keys: State[WebhookKeys], req: Request) raises -> Response:
    var signature = req.headers.get("x-signature")
    if not signature or signature.value() != keys[].secret:
        return Response.text("unsigned", status=401)
    var resp = Response.text("ok")
    resp.headers.add("X-Request-Id", "42")
    return resp^


def make_app() -> App:
    var keys = State(WebhookKeys("sha256=valid"))
    var app = App()
    app.post["/webhook"](webhook, keys)          # app.get too
    return app^
# POST /webhook  X-Signature: sha256=valid  -> 200 "ok", X-Request-Id: 42
# POST /webhook  (no X-Signature)           -> 401 "unsigned"
# GET /webhook                              -> 405 "Method Not Allowed", Allow: POST  (webhook not called)
```

Run by `tests/test_state_examples.mojo` (`test_state_raw`), with `make_app` named `raw_app`, as the first example is; it sends the unsigned request through `app.handle` and the others through `TestClient`.

A typed function value is spelled `def(State[S], var Request) thin raises Never -> Response`.

## Errors

- A stateful handler registered without its state: `constraint failed: State is injected application state; a stateful get handler takes State first, and the state is the registration's second argument` (on `post`, `put`, `patch`: `State is injected application state, not the request body; a stateful post handler takes State first and the body last, and the state is the registration's second argument`).
- A second `State`: `constraint failed: a handler takes at most one State, as its first parameter`.
- A raw stateful shape broken: `a stateful raw get handler takes State first, then only the Request, and returns Response` (and the `post` variants).
- `no matching method`, with candidate notes: a state of another type (`value passed to 'state' cannot be converted from 'State[Cache]' to 'State[Db]'`), the value instead of a handle (`from 'Db' to 'State[Db]'`), a state given to a stateless handler, the state after another parameter, `var db: State[Db]` or `mut db: State[Db]`, or a plain `db: Db` parameter.
- Mutation through `db[]` is `expression must be mutable ...`.
