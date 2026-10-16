"""Copies the Flare adapter (SRC, `adapters/flare`) to DST with
`to_muntin_headers` routed through M3-066's prototype rebuild
(`bench/headers/pieces_rebuild.mojo`, the rebuild M3-066 rejected), for
scripts/bench_headers.sh's `muntin_pieces_server`. The rest of the adapter
is unchanged; the current conversion stays in the copy under another name.
Fails when the adapter no longer has exactly one `to_muntin_headers` to
reroute."""

import shutil
import sys

src, dst = sys.argv[1], sys.argv[2]
shutil.rmtree(dst, ignore_errors=True)
shutil.copytree(src, dst)
path = f"{dst}/muntin_flare.mojo"
text = open(path).read()
head = "def to_muntin_headers(request: FlareRequest) raises -> Headers:\n"
imp = "from muntin import App, Headers, Request, Response\n"
for anchor in (head, imp):
    if text.count(anchor) != 1:
        raise SystemExit(f"error: {path} does not have exactly one {anchor!r}")
text = text.replace(imp, imp + "from pieces_rebuild import rebuild_fields\n")
text = text.replace(
    head,
    head
    + '    """M3-066\'s prototype: the pieces `write_to` writes."""\n'
    + "    var h = rebuild_fields(request.headers)\n"
    + "    if not h:\n"
    + '        raise Error("header pieces mismatch")\n'
    + "    return h.take()\n"
    + "\n\n"
    + "def _encode_to_muntin_headers(request: FlareRequest) raises -> Headers:\n",
)
open(path, "w").write(text)
