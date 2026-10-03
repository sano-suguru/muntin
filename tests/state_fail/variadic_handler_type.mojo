# Must not compile: one generic registration over every handler arity, which
# would let an injected parameter join any shape without a new overload
# family. Mojo 1.1.0 has no variadic function types (M3-001).
# Expected diagnostic (checked by scripts/check.sh): expected a type, not a value


def register[*Ts: AnyType, R: AnyType](h: def(* Ts) thin -> R):
    pass


def h(a: Int, b: String) -> String:
    return b


def main():
    register(h)
