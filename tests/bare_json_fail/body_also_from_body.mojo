# Expected diagnostic (checked by scripts/check.sh): a parameter's type is a JsonFields struct and conforms to FromBody
from muntin import App, JsonFields, FromBody, Response, ToResponse, Json


@fieldwise_init
struct In(FromBody, JsonFields):
    var name: String

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def create(body: In) -> String:
    return body.name


def main():
    var app = App()
    app.post["/x"](create)
