# Must not build (M3-081): a Group is built from its guard and the guard's
# state; one spelled out without them is refused.
# Expected diagnostic (checked by scripts/check.sh): a Group is built from its guard and the guard's state
from muntin import Group


struct Svc(Movable):
    var n: Int

    def __init__(out self):
        self.n = 0


@fieldwise_init
struct User(Movable):
    var name: String


def main():
    var g = Group[Svc, Error, User]()
    _ = g^
