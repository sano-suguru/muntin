# Must build, and is never run (scripts/check.sh builds it only; the
# returned slice dangles). Evidence for docs/ARCHITECTURE.md, "Registration
# structure decision (M3-014)": safe code can return a
# `StringSlice[ImmutAnyOrigin]` into a local that is dropped on return,
# because the explicit `ImmutAnyOrigin` constructor drops the origin the
# compiler would otherwise track. This is why the selected design must not
# accept such a result as text: copying it would read freed memory. Its
# `where` clause rejects it, as production `App.get` does
# (tests/registration_fail/immutable_origin_result_rejected.mojo).
#
# If this file stops building, safe code can no longer erase a local's
# origin this way, and this reason for the clause weakens.


def text_of_local() -> StringSlice[ImmutAnyOrigin]:
    var s = String("a local, dropped on return")
    return StringSlice[ImmutAnyOrigin](s)


def main():
    _ = text_of_local()
