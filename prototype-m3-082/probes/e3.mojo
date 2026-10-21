# Probe e3 (M3-082, Mojo 1.1.0). Builds and runs: a reflection encoder writes
# List[<struct>], Optional[<struct>], Optional[List[Int]] and
# List[List[String]] without __extension (blocker 1 of M3-008).
# Expect: exit 0
# Expect-output: \{"a":\[\{"zip":1\},\{"zip":2\}\],"b":\[3,4\],"c":null,"d":\[5\],"e":\[\["x"\],\[\]\]\}
from muntin import JsonWriter, ToJson


@fieldwise_init
struct Address(Copyable, ToJson):
    var zip: Int

    def write_json(self, mut out: JsonWriter) raises:
        out.begin_object()
        out.field("zip", self.zip)
        out.end_object()


def _w[FT: AnyType](mut out: JsonWriter, ref f: FT) raises:
    comptime if FT == Int:
        out.value(rebind[Int](f))
    elif FT == String:
        out.value(rebind[String](f))
    elif conforms_to(FT, ToJson):
        f.write_json(out)
    elif conforms_to(FT, Iterable):
        comptime E = FT.IteratorType[ImmutAnyOrigin].Element
        comptime if reflect[FT].base_name() == "List":
            comptime assert conforms_to(E, Copyable)
            ref l = rebind[List[E]](f)
            out.begin_array()
            for i in range(len(l)):
                _w[E](out, l[i])
            out.end_array()
        elif reflect[FT].base_name() == "Optional":
            ref o = rebind[Optional[E]](f)
            if o:
                _w[E](out, o.value())
            else:
                out.null()
        else:
            comptime assert False, "unsupported " + reflect[FT].name()
    else:
        comptime assert False, "unsupported " + reflect[FT].name()


@fieldwise_init
struct Box:
    var a: List[Address]
    var b: List[Int]
    var c: Optional[Address]
    var d: Optional[List[Int]]
    var e: List[List[String]]


def write_fields[T: AnyType](value: T, mut out: JsonWriter) raises:
    comptime r = reflect[T]
    comptime names = r.field_names()
    comptime types = r.field_types()
    out.begin_object()
    comptime for i in range(r.field_count()):
        out.name(String(materialize[names[i]]()))
        _w[types[i]](out, r.field_ref[i](value))
    out.end_object()


def main() raises:
    var out = JsonWriter()
    var x = Box([Address(1), Address(2)], [3, 4], None, Optional[List[Int]]([5]), [["x"], []])
    write_fields(x, out)
    print(out^._finish())
