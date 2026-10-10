# Must not compile (M3-009): a `FromJson` type is not a body by itself; it
# is a body through `Json[T]`. `post`'s `FromBody` body rule rejects the
# bare type with its message.
# Expected diagnostic (checked by scripts/check.sh): constraint failed: the handler's parameter is the request body; its type must conform to FromBody or FromBytes
from muntin import App, FromJson, JsonValue


@fieldwise_init
struct CreateUser(FromJson):
    var name: String

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        return Self(value["name"].string())


def create(body: CreateUser) -> String:
    return body.name


def main():
    var app = App()
    app.post["/users"](create)
