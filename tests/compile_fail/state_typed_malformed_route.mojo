# Must not compile: a stateful handler without a route value, returning a
# ToResponse type, on a malformed route literal (M3-003).
# Expected diagnostic (checked by scripts/check.sh): malformed route literal

from muntin import App, Response, State, ToResponse


struct Db(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


@fieldwise_init
struct Count(Movable, ToResponse):
    var n: Int

    def to_response(var self) -> Response:
        return Response.text(String(self.n))


def h(db: State[Db]) -> Count:
    return Count(db[].n)


def main():
    var app = App()
    app.get["users"](h, State(Db(1)))
