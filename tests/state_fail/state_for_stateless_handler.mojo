# Must not compile: a state argument for a handler that takes none has no
# overload; the state is never silently ignored (M3-001).
# Expected diagnostic (checked by scripts/check.sh): cannot be converted from 'def h() thin -> String' to 'def(State[S]) raises Never thin -> String'
from muntin import Request, Response
from state_spike import State, StateApp


struct Db(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


def h() -> String:
    return "x"


def main():
    var app = StateApp()
    app.get["/x"](h, State(Db(1)))
