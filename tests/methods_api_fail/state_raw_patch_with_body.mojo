# Must not compile: A stateful raw `patch` handler with a body after the
# `Request`; the message names the method. Decision:
# docs/history/architecture-decisions.md, "HTTP methods decision (M3-020)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a stateful raw patch handler takes State first, then only the Request, and returns Response
from muntin import App, FromBody, Request, Response, State


struct P(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


struct Note(FromBody, Movable):
    var text: String

    def __init__(out self, var text: String):
        self.text = text^

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def h(p: State[P], req: Request, body: Note) -> Response:
    return Response.text(body.text)


def main():
    var app = App()
    app.patch["/x"](h, State(P(1)))
