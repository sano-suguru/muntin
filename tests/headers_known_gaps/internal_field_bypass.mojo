# Known gap (M3-002): must build, never run (scripts/check.sh). Mojo 1.1.0 has
# no private fields, so code can append to `Headers`' internal lists by name and
# store a value with CR/LF, bypassing `add`'s validation (one list of pairs, so
# names and values cannot desynchronize). The headers API keeps the invariant;
# the backend is the second line: pinned Flare's HeaderMap rejects CR/LF on
# output (docs/history/architecture-decisions.md, "Headers decision (M3-002)").
# If this stops building, Mojo sealed the fields: revisit that note.
from headers_spike import Headers, _Field


def main():
    var h = Headers()
    h._fields.append(_Field("X-Inject", "a\r\nSet-Cookie: evil=1"))
    print(len(h))
