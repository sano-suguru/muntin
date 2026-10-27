# Reads each line of the file named by the first argument as a JSON document
# holding one number, and prints the bits of `float()` in hex, or `raise`.
# scripts/check_json_float.py writes the file and compares the output with
# Python's `float()` (M3-078).
from std.memory import bitcast
from std.sys import argv

from muntin.json import _MAX_BODY_BYTES, _parse_json


def main() raises:
    var text: String
    with open(argv()[1], "r") as f:
        text = f.read()
    # Printed a block of lines at a time, so a large corpus holds one block
    # of answers, not all of them.
    var out = String()
    var held = 0
    for line in text.splitlines():
        try:
            var x = _parse_json(String(line), _MAX_BODY_BYTES).float()
            out += hex(bitcast[DType.uint64](x)) + "\n"
        except:
            out += "raise\n"
        held += 1
        if held == 4096:
            print(out, end="")
            out = String()
            held = 0
    print(out, end="")
