# Must not build (M3-081): a Group's context type is no request slot kind; an
# `Int` context would be read as a route value.
# Expected diagnostic (checked by scripts/check.sh): a Group's context type must not be a request slot kind (a route value, a body, Headers, Request or State): SIMD[DType.int, 1]
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


def int_auth(svc: State[Svc], headers: Headers) raises -> Int:
    return 1


def main():
    _ = Group(int_auth, State(Svc()))
