# Must not build (M3-081): groups do not nest; only an App mounts a Group.
# Expected diagnostic (checked by scripts/check.sh): mount: a Group mounts no Group
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


def main():
    var outer = Group(auth, State(Svc()))
    outer.mount(Group(auth, State(Svc())))
