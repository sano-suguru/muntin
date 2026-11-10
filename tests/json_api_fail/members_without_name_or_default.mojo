# Must not compile (M3-098 prototype): an entry that neither renames nor defaults its field has no initializer.
# Expected diagnostic (checked by scripts/check.sh): no matching function in initialization
from muntin import App, Json, JsonMember, JsonMembers


@fieldwise_init
struct In(JsonMembers):
    var kind: String

    @staticmethod
    def json_members() -> List[JsonMember]:
        return [JsonMember("kind")]


def h(body: Json[In]) -> String:
    return "x"


def main():
    var app = App()
    app.post["/c"](h)
