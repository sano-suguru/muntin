# Must not compile (M3-098 prototype): a Bool default written as a number.
# Expected diagnostic (checked by scripts/check.sh): constraint failed: the default '1' of field on of the JsonFields struct members_default_bool_not_boolean.In does not read as Bool: JSON value is not a boolean
from muntin import App, Json, JsonMember, JsonMembers


@fieldwise_init
struct In(JsonMembers):
    var on: Bool

    @staticmethod
    def json_members() -> List[JsonMember]:
        return [JsonMember("on", default="1")]


def h(body: Json[In]) -> String:
    return "x"


def main():
    var app = App()
    app.post["/c"](h)
