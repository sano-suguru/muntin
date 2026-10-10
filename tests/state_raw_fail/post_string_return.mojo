# Must not compile: a stateful raw handler returns Response, never String
# (M3-007). The stateful raw overload is not viable, so the call reaches the
# stateful String body overload with B = Request, whose guard names the
# stateful raw shape instead of reporting the FromBody constraint.
# Expected diagnostic (checked by scripts/check.sh): constraint failed: Request is the whole request, not a body; a stateful raw handler takes State first, then only the Request, and returns Response
from muntin import App, Request, Response, State


struct Db(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


def h(db: State[Db], req: Request) -> String:
    return req.path


def main():
    var app = App()
    app.post["/x"](h, State(Db(1)))
