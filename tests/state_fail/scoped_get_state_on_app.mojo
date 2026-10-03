# Must not compile (A2): a stateful handler registered on the app itself
# matches no get overload. Unlike A1, no candidate mentions the state: the
# notes list only the M2 shapes (M3-001).
# Expected diagnostic (checked by scripts/check.sh): cannot be converted from 'def h(db: State[Db]) thin -> String' to 'def() raises Never thin -> String'
from muntin import FromBody, Request, Response
from scoped_state_spike import ScopedApp
from state_spike import State


struct Db(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


def h(db: State[Db]) -> String:
    return String(db[].n)


def main():
    var app = ScopedApp()
    app.get["/x"](h)
