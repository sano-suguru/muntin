# Expected diagnostic (checked by scripts/check.sh): the result type is a collection; a bare collection result is a List of a JsonFields struct
from muntin import App, JsonFields


@fieldwise_init
struct Out(JsonFields):
    var n: Int


def show() -> Optional[Out]:
    return None


def main():
    var app = App()
    app.get["/x"](show)
