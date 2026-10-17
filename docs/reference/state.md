# Application state

A handler receives long-lived application data as `State[S]`, passed as the registration's second argument. There are no globals: Mojo 1.1.0 has no module-level variables and handlers cannot capture.

```mojo
from muntin import App, State


struct Users(Movable):
    var names: List[String]

    def get(self, id: Int) raises NotFound -> String:
        ...


def get_user(users: State[Users], id: Int) raises NotFound -> User:
    return User(id, users[].get(id))       # read-only access to the shared value


def main():
    var users = State(Users(load_names()))   # the application builds the value once
    var app = App()                          # App stays non-generic
    app.get["/hello"](hello)                 # stateless handlers: unchanged
    app.get["/users/{id}"](get_user, users)  # the state is the registration's second argument
# GET /users/0  -> get_user(users, 0) -> User(0, "ada").to_response()
# GET /users/9  -> NotFound(9).to_error_response()   (an error type as in errors.md)
# GET /users/x  -> 400 "Bad Request"                 (get_user not called)
```

## Rules

- **Which parameter:** a handler takes state exactly when its registration passes a `State[S]`. Its first parameter is then `State[S]` (the same `S`), and the rest is one of the stateless shapes, bound as before: `def(State[Users], Int, CreateUser)` on `post` is state, route value, body. Request handling is the stateless twin's.
- **Ownership:** `State(value)` takes the value. `State` is a shared handle: the application keeps its own, each registration keeps a copy, and the value is destroyed when the last handle goes. A request borrows the route's handle and copies or allocates nothing.
- **Read-only:** `users[]` is read-only through every handle. A value that must change while serving keeps that mutability in its own fields, under its own rules. A reference from `users[]` lives no longer than its handle (`use of invalidated interior reference` after the handle is reassigned or moved).
- **The state may borrow nothing.** `S` must own its data: `State(value)` does not compile when `S`'s name shows an origin or a parameter pack anywhere (`View[o]`, a closure that captures by reference): `constraint failed: State takes a value that owns its data; this type's name shows an origin or a parameter pack ({}), so it may borrow a value the App outlives: <the type>` ([M3-074](../history/architecture-decisions.md#state-borrowing-decision-m3-074)). The rule reads the type's name, so it also refuses some owned types: a static origin (`StaticString`, `Optional[StaticString]`) and packs (`Tuple`, `Variant`, `List[Tuple[...]]`). Move such a value into a field of the application's own struct (`struct Pair: var value: Tuple[Int, String]`, then `State(Pair(...))`). A type that hides `AnyOrigin` behind a trait's associated type still registers; Muntin claims no memory safety for values built with `AnyOrigin`.
- **Several values:** one `State` per handler; several values are the fields of one state type. Different routes may take different state types.
- **Threads:** with the Flare adapter's `Server`, an `App` and its `State` values stay on one thread for the `App`'s life: `serve(app)` serves on the calling thread, and `serve[make](workers=n)` builds one `App`, with its own `State` values, per worker on its thread. A counter in one worker counts that worker's requests; state every worker must see belongs outside the process. That is the adapter's behavior, not Muntin's: another backend may call an `App` from several threads in turn, and then `State` values must be safe to use on another thread ([testing](testing.md#the-backend-seam)).

State goes first so the body stays last. Access is `state[]` because a struct cannot forward field access.

## `post`, `put` and `patch`

```mojo
def update_user(users: State[Users], id: Int, body: CreateUser) raises NotFound -> User:
    return User(id, users[].get(id) + " as " + body.name)


app.post["/users/{id}"](update_user, users)  # state, route value, body
# POST /users/1 "name=bo" -> update_user(users, 1, CreateUser("bo")) -> User(1, "bob as bo")
# POST /users/9 "name=bo" -> NotFound(9).to_error_response()
# POST /users/x "name=bo" -> 400 "Bad Request"   (from_body and update_user not called)
```

## Raw handlers

```mojo
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


var keys = State(WebhookKeys("sha256=valid"))
app.post["/webhook"](webhook, keys)          # app.get too
# POST /webhook  X-Signature: sha256=valid  -> 200 "ok", X-Request-Id: 42
# POST /webhook  (no X-Signature)           -> 401 "unsigned"
```

A typed function value is spelled `def(State[S], var Request) thin raises Never -> Response`.

## Errors

- A stateful handler registered without its state: `constraint failed: State is injected application state; a stateful get handler takes State first, and the state is the registration's second argument` (on `post`, `put`, `patch`: `State is injected application state, not the request body; a stateful post handler takes State first and the body last, and the state is the registration's second argument`).
- A second `State`: `constraint failed: a handler takes at most one State, as its first parameter`.
- A raw stateful shape broken: `a stateful raw get handler takes State first, then only the Request, and returns Response` (and the `post` variants).
- `no matching method`, with candidate notes: a state of another type (`value passed to 'state' cannot be converted from 'State[Cache]' to 'State[Db]'`), the value instead of a handle (`from 'Db' to 'State[Db]'`), a state given to a stateless handler, the state after another parameter, `var db: State[Db]` or `mut db: State[Db]`, or a plain `db: Db` parameter.
- Mutation through `db[]` is `expression must be mutable ...`.
