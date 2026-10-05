# Must not compile: a carrier inside a carrier. The body type of
# `WithHeaders` must conform to `FromBody`, and a carrier does not, so the
# handler's signature is rejected where it is declared (M3-013;
# docs/ARCHITECTURE.md, "Typed header access decision (M3-012)").
# Expected diagnostic (checked by scripts/check.sh): 'WithHeaders' parameter 'B' has 'FromBody' type, but value has type 'AnyStruct[WithHeaders[Note]]'

from muntin import FromBody, WithHeaders


@fieldwise_init
struct Note(FromBody, Movable):
    var text: String

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def nested(input: WithHeaders[WithHeaders[Note]]) -> String:
    return ""


def main():
    pass
