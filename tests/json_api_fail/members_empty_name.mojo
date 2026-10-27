# Must not compile (M3-098 prototype): an explicit empty member name, which would otherwise read as no name.
# Expected diagnostic (checked by scripts/check.sh): constraint failed: json_members of the JsonFields struct members_empty_name.In gives field limit the empty member name
from muntin import App, Json, JsonMember, JsonMembers


@fieldwise_init
struct In(JsonMembers):
    var limit: Int

    @staticmethod
    def json_members() -> List[JsonMember]:
        return [JsonMember("limit", name="", default="100")]


def h(body: Json[In]) -> String:
    return "x"


def main():
    var app = App()
    app.post["/c"](h)
