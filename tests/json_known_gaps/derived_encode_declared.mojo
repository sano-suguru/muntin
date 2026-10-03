# Must build, never run (M3-008): a reflection-derived `ToJson`-style default
# accepts a conformance whose struct has a field the encoder does not
# support; the error appears only at the first use
# (tests/json_fail/derived_encode_unsupported_field_at_use.mojo). This late,
# deep diagnostic is one reason the first slice has no derived default. If
# this stops building, Mojo checks defaults at conformance: re-measure.
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
    pass
