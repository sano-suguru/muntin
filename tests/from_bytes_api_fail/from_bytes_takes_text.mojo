# Must not compile (M3-041): from_bytes takes the body's bytes, never text; a
# text conversion is FromBody.from_body.
# docs/history/architecture-decisions.md, "Typed binary request bodies decision
# (M3-041)".
# Expected diagnostic (checked by scripts/check.sh): no 'from_bytes' candidates have type 'def(body: List[UInt8]) raises thin -> Payload'
from muntin import FromBytes


struct Payload(FromBytes):
    comptime max_bytes = Int.MAX

    var text: String

    def __init__(out self, text: String):
        self.text = text

    @staticmethod
    def from_bytes(body: String) raises -> Self:
        return Self(body)


def main():
    pass
