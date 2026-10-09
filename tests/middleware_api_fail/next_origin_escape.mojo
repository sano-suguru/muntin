# Must not build (M3-035): a `Next` keeps the origin of the `App` borrow that
# made it; it does not convert to a `Next` of a longer-lived origin, so a
# middleware cannot give it a lifetime beyond its call.
# Expected diagnostic (checked by scripts/check.sh): cannot implicitly convert 'Next[next.o]' value to 'Next[ImmStaticOrigin]'
from muntin import Next, Request, Response


def escape(var request: Request, var next: Next) raises -> Response:
    var kept: Next[ImmStaticOrigin] = next^
    return kept^.run(request^)


def main():
    pass
