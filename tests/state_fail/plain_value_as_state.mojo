# Must not compile: the registration takes a State handle, not the value;
# State has no implicit conversion, so ownership is spelled out (M3-001).
# Expected diagnostic (checked by scripts/check.sh): value passed to 'state' cannot be converted from 'Db' to 'State[Db]'
from muntin import Request, Response
from state_spike import State, StateApp


struct Db(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


def h(db: State[Db]) -> String:
    return String(db[].n)


def main():
    var app = StateApp()
    app.get["/x"](h, Db(1))
