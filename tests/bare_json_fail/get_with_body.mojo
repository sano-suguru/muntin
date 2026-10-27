# Expected diagnostic (checked by scripts/check.sh): takes no request body
from muntin import App, JsonFields, FromBody, Response, ToResponse, Json


@fieldwise_init
struct In(JsonFields):
    var n: Int


def show(body: In) -> String:
    return "x"


def main():
    var app = App()
    app.get["/x"](show)
