# Must not compile: `Int` is `comptime Int = Scalar[DType.int]`, so it cannot
# take an `__extension` conformance (argument conversion uses compile-time
# type equality instead).
# Expected diagnostic (checked by scripts/check.sh): can't find a struct named 'Int'


trait FromArg:
    @staticmethod
    def from_arg(s: String) raises -> Self:
        ...


__extension Int(FromArg):
    @staticmethod
    def from_arg(s: String) raises -> Int:
        return Int(s)


def main():
    pass
