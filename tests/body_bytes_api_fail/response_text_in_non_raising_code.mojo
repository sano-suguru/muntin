# Must not compile (M3-040): `Response.text()` reads the body bytes as strict
# UTF-8 and raises when they are not, so non-raising code cannot call it
# unhandled; the failure is explicit, never a replaced byte.
# Expected diagnostic (checked by scripts/check.sh): cannot call function that may raise in a context that cannot raise
from muntin import Response


def body_text(r: Response) -> String:
    return r.text()


def main():
    _ = body_text(Response(200, "x"))
