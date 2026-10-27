# Expected diagnostic (checked by scripts/check.sh): In has type SIMD[DType.int64, 1], which cannot be read
from muntin import App, JsonFields, FromBody, Response, ToResponse, Json


@fieldwise_init
struct In(JsonFields):
    var n: Int64


def create(body: In) -> String:
    return "x"


def main():
    var app = App()
    app.post["/x"](create)
