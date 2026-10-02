# Built by scripts/check.sh from a directory holding only this file and
# tests/state_spike.mojo, so the application module
# (tests/test_spike_state.mojo) is not on the include path. It registers
# handlers taking a move-only state type and a body type defined here, ones
# the library has never seen, on every stateful shape. If the library named
# an application type in the code this instantiates, the build fails.
# (Mojo 1.1.0 resolves imports lazily, so a bare `import` would not catch
# that.)

from std.os import abort

from muntin import FromBody, Request, Response, ToResponse
from state_spike import State, StateApp


struct Inventory(Movable):
    var items: List[String]

    def __init__(out self, var items: List[String]):
        self.items = items^


@fieldwise_init
struct Item(FromBody, Movable):
    var name: String

    @staticmethod
    def from_body(body: String) raises -> Self:
        if body.byte_length() == 0:
            raise Error("empty")
        return Self(body)


@fieldwise_init
struct Count(Movable, ToResponse):
    var n: Int

    def to_response(var self) -> Response:
        return Response.text(String(self.n), status=201)


def size(inv: State[Inventory]) -> Count:
    return Count(len(inv[].items))


def item(inv: State[Inventory], id: Int) -> String:
    return inv[].items[id]


def add(inv: State[Inventory], var body: Item) -> String:
    return body.name + "/" + String(len(inv[].items))


def put(inv: State[Inventory], id: Int, body: Item) -> Count:
    return Count(id + len(inv[].items))


def raw(inv: State[Inventory], req: Request) -> Response:
    return Response.text(req.body + String(len(inv[].items)))


def main():
    var items = List[String]()
    items.append("a")
    var inv = State(Inventory(items^))
    var app = StateApp()
    app.get["/size"](size, inv)
    app.get["/items/{id}"](item, inv)
    app.post["/items"](add, inv)
    app.post["/items/{id}"](put, inv)
    app.post["/raw"](raw, inv)
    var s = app.handle(Request("GET", "/size"))
    var i = app.handle(Request("GET", "/items/0"))
    var a = app.handle(Request("POST", "/items", "b"))
    var p = app.handle(Request("POST", "/items/2", "b"))
    var r = app.handle(Request("POST", "/raw", "n"))
    var bad = app.handle(Request("POST", "/items", ""))
    if (
        s.status != 201
        or s.body != "1"
        or i.body != "a"
        or a.body != "b/1"
        or p.body != "3"
        or r.body != "n1"
        or bad.status != 400
    ):
        print("unexpected response")
        abort()
