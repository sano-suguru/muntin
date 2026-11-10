# Must not compile (M3-098 prototype): `json_members` declared without
# `@staticmethod`, which a provided default would have ignored silently.
# Expected diagnostic (checked by scripts/check.sh): no 'json_members' candidates have type 'def() thin -> List[JsonMember]'
from muntin import JsonMember, JsonMembers


@fieldwise_init
struct In(JsonMembers):
    var kind: String

    def json_members(self) -> List[JsonMember]:
        return [JsonMember("kind", name="type")]


def main():
    pass
