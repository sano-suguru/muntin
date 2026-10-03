# Must not compile: a second handle cannot replace the shared value; the
# sealed box has no subscript (M3-003, decided in M3-004).
# Expected diagnostic (checked by scripts/check.sh): is not subscriptable
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
    ref r = a[]
    b._shared[] = OwnedPointer(Db(2))
    print(r.n)
