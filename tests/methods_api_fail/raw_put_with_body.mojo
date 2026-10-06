# Must not compile: A `Request` then a body on `put` breaks the raw rule; the
# message names the method. Decision: docs/history/architecture-decisions.md,
# "HTTP methods decision (M3-020)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a raw put handler takes only the Request and returns Response
from muntin import App, FromBody, Request, Response


struct Note(FromBody, Movable):
    var text: String

    def __init__(out self, var text: String):
        self.text = text^

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def h(req: Request, body: Note) -> Response:
    return Response.text(body.text)


def main():
    var app = App()
    app.put["/x"](h)
