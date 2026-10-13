# Must not compile: the ToResponse twin of post_int_int.mojo, on a query
# route value: the same rule and message (M2-009, M3-048).
# Expected diagnostic (checked by scripts/check.sh): handler takes two route values; route must declare exactly two path or query parameters

from muntin import App, Response, ToResponse


struct User(ToResponse):
    var id: Int

    def __init__(out self, id: Int):
        self.id = id

    def to_response(var self) -> Response:
        return Response.text(String(self.id))


def h(a: Int, b: Int) -> User:
    return User(a)


def main():
    var app = App()
    app.post["/users?{id}"](h)
