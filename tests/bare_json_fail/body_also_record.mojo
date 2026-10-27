# Expected diagnostic (checked by scripts/check.sh): a parameter's type is a JsonFields struct and conforms to FromBody, FromBytes, FromRouteValue or RouteValues
from muntin import App, JsonFields, RouteValues


@fieldwise_init
struct In(JsonFields, RouteValues):
    var id: Int


def show(values: In) -> String:
    return String(values.id)


def main():
    var app = App()
    app.get["/x/{id}"](show)
