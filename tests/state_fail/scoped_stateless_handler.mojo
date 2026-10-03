# Must not compile (A2): a registrar registers only stateful handlers; a
# stateless one belongs on the app (M3-001).
# Expected diagnostic (checked by scripts/check.sh): cannot be converted from 'def h() thin -> String' to 'def(State[Db]) raises Never thin -> String'
from muntin import FromBody, Request, Response
from scoped_state_spike import ScopedApp
from state_spike import State


struct Db(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


def h() -> String:
    return "x"


def main():
    var app = ScopedApp()
    app.with_state(State(Db(1))).get["/x"](h)
