# Must not compile (pull request #136): `to_flare_response` takes the
# response, so a caller hands it over (`^`) or copies it itself (`.copy()`),
# and the adapter moves its body into Flare's response instead of copying it.
# If this builds, a named response is being copied implicitly again: check
# that `to_flare_response` still takes `var response`.
# Expected diagnostic (checked by scripts/check_flare.sh): value of type 'Response' cannot be implicitly copied
from muntin import Response
from muntin_flare import to_flare_response


def main():
    var response = Response(200, "kept")
    _ = to_flare_response(response)
    _ = response.status
