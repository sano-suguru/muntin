# Must not compile (M3-098 prototype): a defaulted member whose type is not Copyable.
# Expected diagnostic (checked by scripts/check.sh): constraint failed: field token of the JsonFields struct members_default_not_copyable.In is defaulted, but its type members_default_not_copyable.Token is not Copyable
from muntin import (
    App,
    FromJson,
    Json,
    JsonDefault,
    JsonMember,
    JsonMembers,
    JsonValue,
)


struct Token(FromJson, Movable):
    var v: Int

    def __init__(out self, v: Int):
        self.v = v

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        return Self(value.int())


@fieldwise_init
struct In(JsonDefault, JsonMembers):
    var token: Token

    @staticmethod
    def json_members() -> List[JsonMember]:
        return [JsonMember("token", default=True)]

    @staticmethod
    def json_default() -> Self:
        return Self(Token(0))


def h(body: Json[In]) -> String:
    return "x"


def main():
    var app = App()
    app.post["/c"](h)
