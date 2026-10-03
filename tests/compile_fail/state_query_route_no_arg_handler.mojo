# Must not compile: a route with a query parameter, a stateful handler that
# takes no route value (M3-003).
# Expected diagnostic (checked by scripts/check.sh): route declares a query parameter but the handler takes none

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
    app.get["/x?{limit}"](h, State(Db(1)))
