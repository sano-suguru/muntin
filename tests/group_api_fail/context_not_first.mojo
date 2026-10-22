# Must not build (M3-081): a handler receives the Group's context only as its
# first request parameter, and the message names the context type.
# Expected diagnostic (checked by scripts/check.sh): a Group's handler takes the group's context type once, as its first request parameter (after State, if any): context_not_first.User
from muntin import Group, Headers, State


struct Svc(Movable):
    var n: Int

    def __init__(out self):
        self.n = 0


@fieldwise_init
struct User(Movable):
    var name: String


def auth(svc: State[Svc], headers: Headers) raises -> User:
    return User("ada")


def me(id: Int, user: User) -> String:
    return user.name


def main():
    var g = Group(auth, State(Svc()))
    g.get["/me/{id}"](me)
