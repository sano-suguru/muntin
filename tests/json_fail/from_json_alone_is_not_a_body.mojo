# Must not compile (M3-008, candidate 4 rejected): a JSON-capable type is not
# a body by itself. Taking it directly would need a new `post` overload
# family (`B: FromJson`), so `post`'s `FromBody` body rule rejects it.
# Expected diagnostic (checked by scripts/check.sh): constraint failed: the handler's parameter is the request body; its type must conform to FromBody
from muntin import App
from json_spike import FromJson, JsonValue


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
