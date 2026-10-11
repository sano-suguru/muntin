# Must not compile (M3-043): a type declares its max_bytes once; a second
# declaration is a redefinition, so a limit is never set twice.
# docs/history/architecture-decisions.md, "Typed binary request body size
# limits decision (M3-043)".
# Expected diagnostic (checked by scripts/check.sh): invalid redefinition of 'max_bytes'
from muntin import FromBytes


struct Twice(FromBytes):
    comptime max_bytes = 1024
    comptime max_bytes = 2048

    var n: Int

    def __init__(out self, n: Int):
        self.n = n

    @staticmethod
    def from_bytes(body: List[UInt8]) raises -> Self:
        return Self(len(body))


def main():
    print(Twice.max_bytes)
