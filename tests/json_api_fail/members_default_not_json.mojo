# Must not compile (M3-098 prototype): a default that is not JSON text (a string default unquoted).
# Expected diagnostic (checked by scripts/check.sh): constraint failed: the default 'new' of field sort of the JsonFields struct members_default_not_json.In does not read as String: invalid JSON
from muntin import App, Json, JsonMember, JsonMembers


@fieldwise_init
struct In(JsonMembers):
    var sort: String

    @staticmethod
    def json_members() -> List[JsonMember]:
        return [JsonMember("sort", default="new")]


def h(body: Json[In]) -> String:
    return "x"


def main():
    var app = App()
    app.post["/c"](h)
