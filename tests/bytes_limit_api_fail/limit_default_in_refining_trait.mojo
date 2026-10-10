# Must not compile (M3-043): an application trait refining FromBytes cannot
# give max_bytes a second default; the type that conforms states its own.
# docs/history/architecture-decisions.md, "Typed binary request body size
# limits decision (M3-043)".
# Expected diagnostic (checked by scripts/check.sh): trait member 'max_bytes' has conflicting default implementations in FromBytes and Small; you must implement it manually
from muntin import FromBytes


trait Small(FromBytes):
    comptime max_bytes: Int = 16


struct Icon(Small):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n

    @staticmethod
    def from_bytes(body: List[UInt8]) raises -> Self:
        return Self(len(body))


def main():
    print(Icon.max_bytes)
