# Must not compile (M3-008): every writer call raises (structure, non-finite
# numbers), so `write_json` is `raises`; a non-raising implementation that
# writes does not compile.
# Expected diagnostic (checked by scripts/check.sh): cannot call function that may raise in a context that cannot raise
from json_spike import JsonWriter


def write(mut out: JsonWriter):
    out.int(1)


def main():
    var w = JsonWriter()
    write(w)
