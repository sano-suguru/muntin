# Must not compile: the ToResponse twin of post_int_int.mojo, on a query
# route value, repeats its Int guard and message (M2-009).
# Expected diagnostic (checked by scripts/check.sh): Int is a route-value type, never the request body; the body parameter's type must conform to FromBody or FromBytes

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
