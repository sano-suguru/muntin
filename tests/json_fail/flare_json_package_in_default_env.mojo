# Must not compile (M3-008): the only JSON package on the pinned lock ships
# inside Flare's conda package (lib/mojo/json, with libsimdjson_wrapper), so
# it exists only in the `flare` environment; Muntin core cannot import it.
# Expected diagnostic (checked by scripts/check.sh): unable to locate module 'json'
from json import loads


def main() raises:
    _ = loads("1")
