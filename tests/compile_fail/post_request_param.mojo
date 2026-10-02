# Must not compile: a raw Request parameter on App.post with a String result.
# Raw handlers return Response (M2-015), so no raw overload is viable and
# the call reaches the String body overload with B = Request, whose
# type-equality guard names the raw shape instead of the FromBody constraint.
# Expected diagnostic (checked by scripts/check.sh): Request is the whole request, not a body; a raw handler takes only the Request and returns Response

from muntin import App, FromBody, Request, Response


struct CreateUser(FromBody):
    var name: String

    def __init__(out self, name: String):
        self.name = name

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def h(request: Request) -> String:
    return request.body


def main():
    var app = App()
    app.post["/users"](h)
