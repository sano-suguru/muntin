# Must not build (M3-081): `StaticString` is a slice type whose name shows an
# origin, so the name filter (M3-074) refuses it as a Group's context type;
# an application wraps such a value in a struct of its own.
# Expected diagnostic (checked by scripts/check.sh): a Group's context type must own its data; its name shows an origin or a parameter pack: std.collections.string.string_span.StringSpan[False, {}, {}]
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


def static_auth(svc: State[Svc], headers: Headers) raises -> StaticString:
    return "ada"


def main():
    _ = Group(static_auth, State(Svc()))
