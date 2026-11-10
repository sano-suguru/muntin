# Must not compile (M3-098 prototype): a json_members entry naming no field, in a body.
# Expected diagnostic (checked by scripts/check.sh): constraint failed: json_members of the JsonFields struct members_unknown_field.In names kind_, which is not one of its fields
from muntin import App, Json, JsonMember, JsonMembers


@fieldwise_init
struct In(JsonMembers):
    var kind: String

    @staticmethod
    def json_members() -> List[JsonMember]:
        return [JsonMember("kind_", name="type")]


def h(body: Json[In]) -> String:
    return "x"


def main():
    var app = App()
    app.post["/c"](h)
