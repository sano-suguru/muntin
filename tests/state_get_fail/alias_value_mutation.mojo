# Must not compile: a second handle cannot mutate the shared value, here
# freeing a list a reference from the first handle points into (M3-003,
# decided in M3-004).
# Expected diagnostic (checked by scripts/check.sh): invalid use of mutating method
from std.memory import OwnedPointer
from muntin import State


struct Db(Movable):
    var n: Int
    var names: List[String]

    def __init__(out self, n: Int):
        self.n = n
        self.names = List[String]()


def main():
    var a = State(Db(1))
    var b = a.copy()
    ref names = a[].names
    b._shared.owned()[].names.clear()
    print(len(names))
