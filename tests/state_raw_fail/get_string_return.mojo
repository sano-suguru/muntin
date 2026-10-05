# Must not compile: a stateful raw handler returns Response, never String
# (M3-007). It selects get's stateful one-slot overload, whose rule check
# reports the raw rule (M3-015).
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a stateful raw get handler takes State first, then only the Request, and returns Response
from muntin import App, Request, Response, State


struct Db(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


def h(db: State[Db], req: Request) -> String:
    return req.body


def main():
    var app = App()
    app.get["/x"](h, State(Db(1)))
