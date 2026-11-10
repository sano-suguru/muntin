# Must not compile (M3-098 prototype): a field named by two json_members entries.
# Expected diagnostic (checked by scripts/check.sh): constraint failed: json_members of the JsonFields struct members_field_twice.In names field kind twice
from muntin import App, Json, JsonMember, JsonMembers


@fieldwise_init
struct In(JsonMembers):
    var kind: String

    @staticmethod
    def json_members() -> List[JsonMember]:
        return [JsonMember("kind", name="type"), JsonMember("kind", name="k")]


def h(body: Json[In]) -> String:
    return "x"


def main():
    var app = App()
    app.post["/c"](h)
