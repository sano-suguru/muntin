# Expected diagnostic (checked by scripts/check.sh): Out has type SIMD[DType.int64, 1], which cannot be written
from muntin import App, JsonFields, FromBody, Response, ToResponse, Json


@fieldwise_init
struct Out(JsonFields):
    var n: Int64


def show() -> List[Out]:
    return []


def main():
    var app = App()
    app.get["/x"](show)
