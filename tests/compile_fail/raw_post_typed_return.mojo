# Must not compile: a raw Request parameter on App.post with a ToResponse
# result other than Response. Raw handlers return Response only (M2-015); the
# call reaches the generic body overload with B = Request, whose guard names
# the raw shape.
# Expected diagnostic (checked by scripts/check.sh): Request is the whole request, not a body; a raw handler takes only the Request and returns Response

from muntin import App, Request, Response, ToResponse


@fieldwise_init
struct Echo(Movable, ToResponse):
    var text: String

    def to_response(var self) -> Response:
        return Response.text(self.text)


def h(req: Request) -> Echo:
    return Echo(req.body)


def main():
    var app = App()
    app.post["/hooks"](h)
