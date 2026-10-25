# Must not compile (M3-089 prototype): FromBody gives max_bytes a default,
# so a trait refining it cannot give its family another one; Mojo 1.1.0
# rejects the conflicting defaults where a type conforms. The compiler's
# check, not Muntin's (a FromBytes family default compiles, M3-043).
# Expected diagnostic (checked by scripts/check.sh): trait member 'max_bytes' has conflicting default implementations
from muntin import FromBody


trait SmallText(FromBody):
    comptime max_bytes: Int = 4096


struct Note(SmallText):
    var text: String

    def __init__(out self, var text: String):
        self.text = text^

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def main():
    print(Note.max_bytes)
