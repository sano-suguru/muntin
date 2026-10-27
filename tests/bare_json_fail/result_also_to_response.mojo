# Expected diagnostic (checked by scripts/check.sh): the result type is a JsonFields struct and conforms to ToResponse
from muntin import App, JsonFields, FromBody, Response, ToResponse, Json


@fieldwise_init
struct Out(JsonFields, ToResponse):
    var name: String

    def to_response(var self) -> Response:
        return Response.text(self.name)


def show() -> Out:
    return Out("a")


def main():
    var app = App()
    app.get["/x"](show)
