# Must not compile (M3-091 prototype): a `Group`'s routes are documented
# once mounted, so `openapi` is the `App`'s alone.
# Expected diagnostic (checked by scripts/check.sh): openapi: mount the Group first
# Build flags (scripts/build_one.sh): -D MUNTIN_OPENAPI
from muntin import Group, Headers, State


@fieldwise_init
struct Member(Movable):
    var name: String


def guard(s: State[Int], h: Headers) raises -> Member:
    return Member("ada")


def me(m: Member) -> String:
    return m.name


def main() raises:
    var members = Group(guard, State(1))
    members.get["/me"](me)
    print(members.openapi(title="T", version="1"))
