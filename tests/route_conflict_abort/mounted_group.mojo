# A mounted Group's route is checked against the App's earlier routes as its
# own registration on the App would be (M3-081): a route that a parameter
# route registered earlier covers aborts at `mount`.
# Expected diagnostic (checked by scripts/check.sh): route conflict: GET /notes/new is registered after GET /notes/{id}, which matches every request it matches; register GET /notes/new first
from muntin import App, Group, Headers, State


@fieldwise_init
struct Svc(Movable):
    var n: Int


@fieldwise_init
struct User(Movable):
    var name: String


def auth(svc: State[Svc], headers: Headers) raises -> User:
    return User("ada")


def note(id: Int) -> String:
    return String(id)


def new_note(user: User) -> String:
    return user.name


def main():
    var app = App()
    app.get["/notes/{id}"](note)
    var g = Group(auth, State(Svc(0)))
    g.get["/notes/new"](new_note)
    app.mount(g^)
