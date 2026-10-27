# Must not compile (M3-098 prototype): a default for a field read by a
# hand-written `from_json`, which a compile-time read would have to run.
# Expected diagnostic (checked by scripts/check.sh): constraint failed: the default '"t"' of field token of the JsonFields struct members_default_hand_written.In is for a members_default_hand_written.Token: a default is read at compile time, where no application code runs
from muntin import App, FromJson, Json, JsonMember, JsonMembers, JsonValue


@fieldwise_init
struct Token(FromJson):
    var v: String

    @staticmethod
    def from_json(value: JsonValue) raises -> Self:
        return Self(value.string())


@fieldwise_init
struct In(JsonMembers):
    var token: Token

    @staticmethod
    def json_members() -> List[JsonMember]:
        return [JsonMember("token", default='"t"')]


def h(body: Json[In]) -> String:
    return "x"


def main():
    var app = App()
    app.post["/c"](h)
