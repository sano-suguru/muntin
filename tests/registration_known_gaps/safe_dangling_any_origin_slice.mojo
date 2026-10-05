# Must build, and is never run (scripts/check.sh builds it only; running it
# reads freed memory). Evidence for docs/ARCHITECTURE.md, "Registration
# structure decision (M3-014)": safe code can return a
# `StringSlice[ImmutAnyOrigin]` into a local that is dropped on return,
# because the explicit `ImmutAnyOrigin` constructor drops the origin the
# compiler would otherwise track. A handler declared with that result is
# accepted by the selected design (tests/registration_known_gaps/
# generic_equality_merges_static_and_any_origin.mojo), which copies the
# result into a `String` right after the handler returns. The dangling
# slice comes from the application's own conversion, outside Muntin's
# guarantee, like the toolchain-wide gaps of "State storage decision
# (M3-004)".
#
# If this file stops building, safe code can no longer erase a local's
# origin this way: the third accepted-set change no longer admits a
# dangling result from safe code.


def text_of_local() -> StringSlice[ImmutAnyOrigin]:
    var s = String("a local, dropped on return")
    return StringSlice[ImmutAnyOrigin](s)


def main():
    _ = text_of_local()
