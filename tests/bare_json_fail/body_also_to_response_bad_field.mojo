# Expected diagnostic (checked by scripts/check.sh): In has type SIMD[DType.int64, 1], which cannot be read
from muntin import App, JsonFields, Response, ToResponse


@fieldwise_init
struct In(JsonFields, ToResponse):
    var n: Int64

    def to_response(var self) -> Response:
        return Response.text("x")


def create(body: In) -> String:
    return "x"


def main():
    var app = App()
    app.post["/x"](create)
