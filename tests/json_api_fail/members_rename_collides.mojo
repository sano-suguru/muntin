# Must not compile (M3-098 prototype): a rename onto another field's member, in a result.
# Expected diagnostic (checked by scripts/check.sh): constraint failed: fields kind and type of the JsonFields struct members_rename_collides.Out are both member type
from muntin import App, Json, JsonMember, JsonMembers


@fieldwise_init
struct Out(JsonMembers):
    var kind: String
    var type: String

    @staticmethod
    def json_members() -> List[JsonMember]:
        return [JsonMember("kind", name="type")]


def h() -> Json[Out]:
    return Json(Out("a", "b"))


def main():
    var app = App()
    app.get["/c"](h)
