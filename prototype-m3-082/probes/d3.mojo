# Probe d3 (M3-082, Mojo 1.1.0). Builds and runs, unsoundly: a trait-default
# `__init__(out self)` assigning through field_ref destroys the uninitialized
# old value first ("del <garbage>" before each "assign"); the rejected
# decoding candidate.
@fieldwise_init
struct Noisy(Movable):
    var tag: Int
    def __del__(deinit self):
        print("del", self.tag)

trait Derive(Movable):
    def __init__(out self, n: Int):
        comptime r = reflect[Self]
        comptime types = r.field_types()
        comptime for i in range(r.field_count()):
            comptime if types[i] == Noisy:
                print("assign", i)
                rebind[Noisy](r.field_ref[i](self)) = Noisy(n + i)


struct P(Derive):
    var a: Noisy
    var b: Noisy


def main():
    var p = P(50)
    print("built", p.a.tag, p.b.tag)
