# Must not compile on 1.1.0: in the trait's own module, `__extension SIMD(FB)`
# satisfies a `[T: FB]` bound for `Int` (`via_bound[Int]` below compiles),
# yet `conforms_to(Int, FB)` is False. So a conformance check cannot be the
# only thing keeping builtins out of the body slot, and a Muntin-side
# extension of a builtin would be invisible to `comptime assert conforms_to`.
# If this compiles, `conforms_to` sees extensions; revisit the decision.
# Expected diagnostic (checked by scripts/check.sh): constraint failed: conforms_to does not see the extension


trait FB(Deinitable, Movable):
    @staticmethod
    def from_body(body: String) raises -> Self:
        ...


__extension SIMD(FB):
    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(0)


def via_bound[T: FB](raw: String) raises -> T:
    return T.from_body(raw)


def main() raises:
    _ = via_bound[Int]("x")
    comptime assert conforms_to(
        Int, FB
    ), "conforms_to does not see the extension"
