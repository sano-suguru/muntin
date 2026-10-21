# Must not build (M3-081): a Group answers no request until it is mounted
# into an App; its `handle`, which a backend would call, is refused.
# Expected diagnostic (checked by scripts/check.sh): a Group is mounted, not served
from muntin import Group, Headers, Request, State


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
    var g = Group(auth, State(Svc()))
    _ = g.handle(Request("GET", "/"))
