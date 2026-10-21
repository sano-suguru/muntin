# Must not build (M3-081): a Group's context type must own its data, by the
# name filter `State` uses (M3-074): a type whose name shows an origin may
# borrow a local the App outlives, and the guard's value is moved into a
# handler long after the guard returns.
# Expected diagnostic (checked by scripts/check.sh): a Group's context type must own its data; its name shows an origin or a parameter pack: context_borrows_local.View[{}, {}]
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


struct View[o: Origin[mut=False]](Movable):
    var p: Pointer[String, Self.o]

    def __init__(out self, ref[Self.o] s: String):
        self.p = Pointer(to=s)


def view_auth[
    o: Origin[mut=False]
](svc: State[Svc], headers: Headers) raises -> View[o]:
    raise Error("no")


def main():
    var local = String("x")
    _ = Group(view_auth[origin_of(local)], State(Svc()))
