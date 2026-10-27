# Expected diagnostic (checked by scripts/check.sh): a Group's context type must not be a JsonFields struct or a List of one, which is a request body (M3-096); wrap it in a struct of the application's own: group_context.User
from muntin import App, Group, Headers, JsonFields, State


@fieldwise_init
struct User(JsonFields):
    var name: String


@fieldwise_init
struct Svc(Movable):
    var key: String


def authenticate(svc: State[Svc], headers: Headers) raises -> User:
    return User("ann")


def main():
    var app = App()
    var g = Group(authenticate, State(Svc("k")))
    app.mount(g^)
