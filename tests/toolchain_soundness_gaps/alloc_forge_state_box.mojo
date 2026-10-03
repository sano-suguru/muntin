# Mojo 1.1.0 toolchain-wide soundness gap: must build, never run
# (scripts/check.sh). It breaks the property M3-004 guarantees, one State
# alias replacing, mutating or destroying the payload another alias
# observes, but through a primitive that breaks the same property for
# standard-library types and existing Muntin storage, so it is outside the
# guarantee (docs/ARCHITECTURE.md, "State storage decision (M3-004)").
# If this stops building, the toolchain improved: reevaluate whether the
# sealed box and its unsafe boundary can be simplified.
#
# Primitive: forged allocation. Public `alloc` makes an uninitialized
# header, and `swap` puts it in place of a box's header through Muntin's
# internal field name; the real header is dropped through a sink.
from std.memory.alloc import Layout, alloc
from state_storage_spike import State, _Shared, _SharedHeader


struct Db(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


def main():
    var a = State(Db(1))
    var fake = alloc(Layout[_SharedHeader[Db]].single()).into_thin()
    swap(a._shared._header, fake)
    var sink: _Shared[Db]
    sink._header = fake^
    print(a[].n)
