# Probe g2 (M3-082, Mojo 1.1.0). Does not build: the same struct used as a
# Json result fails only at first use, about 90 lines deep, message last.
from muntin import JsonWriter, ToJson


def write_fields[T: AnyType](value: T, mut out: JsonWriter) raises:
    comptime r = reflect[T]
    comptime names = r.field_names()
    comptime types = r.field_types()
    out.begin_object()
    comptime for i in range(r.field_count()):
        comptime FT = types[i]
        out.name(String(materialize[names[i]]()))
        comptime if FT == Int:
            out.int(rebind[Int](r.field_ref[i](value)))
        else:
            comptime assert False, (
                "derived JSON: field '" + String(names[i]) + "' has unsupported type " + reflect[FT].name()
            )
    out.end_object()


@fieldwise_init
struct Counts(ToJson):
    var total: Int
    var by_name: Dict[String, Int]

    def write_json(self, mut out: JsonWriter) raises:
        write_fields(self, out)


from muntin import App, Json


def counts() -> Json[Counts]:
    return Json(Counts(1, {}))


def main():
    var app = App()
    app.get["/counts"](counts)
