# Expected diagnostic (checked by scripts/check.sh): a parameter's type is a JsonFields struct and conforms to FromBody, FromBytes, FromRouteValue or RouteValues
from muntin import App, FromRouteValue, JsonFields


struct In(FromRouteValue, JsonFields):
    var name: String

    def __init__(out self, name: String):
        self.name = name

    @staticmethod
    def from_route_value(value: String) raises -> Self:
        return Self(value)


def create(body: In) -> String:
    return body.name


def main():
    var app = App()
    app.post["/x"](create)
