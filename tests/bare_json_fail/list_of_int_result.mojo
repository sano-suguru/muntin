# Expected diagnostic (checked by scripts/check.sh): the result type is a collection; a bare collection result is a List of a JsonFields struct
from muntin import App, JsonFields, FromBody, Response, ToResponse, Json


def show() -> List[Int]:
    return [1]


def main():
    var app = App()
    app.get["/x"](show)
