# Must not compile: a stateful Int handler returning a ToResponse type on a
# route with two parameters (M3-003).
# Expected diagnostic (checked by scripts/check.sh): handler takes one Int parameter; route must declare exactly one path or query parameter

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


def h(db: State[Db], id: Int) -> Count:
    return Count(db[].n + id)


def main():
    var app = App()
    app.get["/x/{id}?{limit}"](h, State(Db(1)))
