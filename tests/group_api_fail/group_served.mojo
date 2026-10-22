# Must not build (M3-081): a Group answers no request until it is mounted into
# an App; `TestClient`, like a backend, takes only an App.
# Expected diagnostic (checked by scripts/check.sh): cannot be converted from '_App[Svc, Error, User]' to ref '_App[_NoGuardState, Never, _NoContext]'
from muntin import Group, Headers, State
from muntin.testing import TestClient


struct Svc(Movable):
    var n: Int

    def __init__(out self):
        self.n = 0


@fieldwise_init
struct User(Movable):
    var name: String


def auth(svc: State[Svc], headers: Headers) raises -> User:
    return User("ada")


def main() raises:
    var g = Group(auth, State(Svc()))
    _ = TestClient(g).get("/")
