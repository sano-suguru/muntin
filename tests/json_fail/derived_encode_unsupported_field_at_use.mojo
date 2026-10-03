# Must not compile (M3-008): the same derived default as
# tests/json_known_gaps/derived_encode_declared.mojo fails only where it is
# first used, as a "constraint failed" note under "function instantiation
# failed", not at the struct's conformance.
# Expected diagnostic (checked by scripts/check.sh): constraint failed: derived JSON: unsupported field type std.collections.dict.Dict[String
from std.collections import Dict
from std.reflection import reflect


trait DerivedJson:
    def to_text(self) -> String:
        var out = String("{")
        comptime n = reflect[Self].field_count()
        comptime types = reflect[Self].field_types()
        comptime for i in range(n):
            comptime FT = types[i]
            ref f = reflect[Self].field_ref[i](self)
            comptime if FT == Int:
                out += String(rebind[Int](f))
            else:
                comptime assert False, (
                    "derived JSON: unsupported field type " + reflect[FT].name()
                )
        out += "}"
        return out


@fieldwise_init
struct Counts(DerivedJson):
    var total: Int
    var by_name: Dict[String, Int]


def main():
    print(Counts(1, {}).to_text())
