# Must not build (M3-081): a stateful handler registered on a Group without its
# state gets the rules' message about the state, as on an App, even though its
# context follows the `State`.
# Expected diagnostic (checked by scripts/check.sh): State is injected application state; a stateful get handler takes State first, and the state is the registration's second argument
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


def me(svc: State[Svc], user: User) -> String:
    return user.name


def main():
    var g = Group(auth, State(Svc()))
    g.get["/me"](me)
