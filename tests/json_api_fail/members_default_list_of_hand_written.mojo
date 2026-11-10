# Must not compile (M3-098 prototype): a non-empty default of a List of a
# type with a hand-written `from_json`, which a compile-time read would run.
# Expected diagnostic (checked by scripts/check.sh): constraint failed: the default '["t"]' of field tokens of the JsonFields struct members_default_list_of_hand_written.In is not []
from muntin import App, FromJson, Json, JsonMember, JsonMembers, JsonValue


@fieldwise_init
struct Token(FromJson):
    var v: String

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        return Self(value.string())


@fieldwise_init
struct In(JsonMembers):
    var tokens: List[Token]

    @staticmethod
    def json_members() -> List[JsonMember]:
        return [JsonMember("tokens", default='["t"]')]


def h(body: Json[In]) -> String:
    return "x"


def main():
    var app = App()
    app.post["/c"](h)
