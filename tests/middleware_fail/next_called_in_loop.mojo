# Must not compile (M3-034): a `Next` consumed inside a loop would run the rest
# once per iteration; the compiler rejects the second iteration's use.
# Expected diagnostic (checked by scripts/check.sh): use of uninitialized value 'next'
from muntin import Request, Response
from middleware_spike import Next


def retry(var request: Request, var next: Next) raises -> Response:
    var response = Response.text("unused")
    for _ in range(2):
        response = next^.run(request.copy())
    return response^


def main():
    pass
