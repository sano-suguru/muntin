# Must not compile (M3-044): `Server.bind`'s receive body limit is the
# keyword-only `max_body_bytes`; a bare number after the port is not
# accepted. This fails the same way before M3-044 (when `bind` took two
# arguments), so it pins the keyword-only spelling rather than proving it.
# If this builds, revisit the spelling in docs/history/architecture-decisions.md
# "Server receive body limit decision (M3-044)".
# Expected diagnostic (checked by scripts/check_flare.sh): invalid call to 'bind': unexpected argument
from muntin_flare import Server


def main() raises:
    _ = Server.bind("127.0.0.1", 0, 1024)
