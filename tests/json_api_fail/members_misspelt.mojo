# Must not compile (M3-098 prototype): a misspelt `json_members`, which a
# provided default would have ignored silently.
# Expected diagnostic (checked by scripts/check.sh): required function 'json_members' is not implemented
from muntin import JsonMember, JsonMembers


@fieldwise_init
struct In(JsonMembers):
    var kind: String

    @staticmethod
    def json_member() -> List[JsonMember]:
        return [JsonMember("kind", name="type")]


def main():
    pass
