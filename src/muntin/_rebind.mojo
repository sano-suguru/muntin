"""The rebinds of `src/muntin` (M3-015, M3-082): a value or a reference of
generic type `T` reached as `A`, which must be the same type.

`comptime if A == Int` does not refine `A` on Mojo 1.1.0
(tests/header_access_fail/generic_slot_does_not_refine.mojo), so a generic
slot, result or JSON field reaches its type through a rebind, and the rebind
alone also accepts a different type with the same layout
(tests/registration_known_gaps/rebind_var_layout_twins.mojo). Each helper
asserts type equality first. The equality is exact for origin-free types
(`Int`, `String`, their `Optional`s and `List`s, `Request`, `Headers`);
generic `==` ignores which origin a slice has, so for a `StaticString` result
exactness comes from the overloads' `where` clause. The confinement step of
`scripts/check.sh` requires each rebind on the line after its assert, here
and nowhere else.
"""

from std.builtin.rebind import rebind_var


def _as[T: Movable, A: Movable](var value: T) -> A:
    """`value` as `A`, which must equal `T`."""
    comptime assert A == T, "rebind requires generic type equality"
    return rebind_var[A](value^)


def _view[A: AnyType, T: AnyType](ref value: T) -> ref[value] A:
    """A reference to `value` as `A`, which must equal `T`."""
    comptime assert A == T, "rebind requires generic type equality"
    return rebind[A](value)
