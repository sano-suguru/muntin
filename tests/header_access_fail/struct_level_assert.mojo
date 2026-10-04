# Must not compile: a compile-time header name checked where the type is
# declared. Mojo 1.1.0 allows `comptime assert` only inside a function, so
# a carrier parameterized by a header name can reject an invalid name only
# when a function using it is instantiated (at the registration), as
# "function instantiation failed" (docs/ARCHITECTURE.md, "Typed header
# access decision (M3-012)", compile-time names). The name used is valid,
# so the struct-level assert is the only error: if Mojo starts accepting
# it, this compiles; revisit compile-time header names then.
# Expected diagnostic (checked by scripts/check.sh): 'comptime assert' must be inside a function


def _token(name: StaticString) -> Bool:
    if name.byte_length() == 0:
        return False
    for b in name.as_bytes():
        if Int(b) <= 32 or Int(b) >= 127 or Int(b) == ord(":"):
            return False
    return True


struct NamedHeader[name: StaticString]:
    comptime assert _token(Self.name), "header name must be a token"
    var value: String

    def __init__(out self, value: String):
        self.value = value


def main():
    var h = NamedHeader["x-api-key"]("v")
    print(h.value)
