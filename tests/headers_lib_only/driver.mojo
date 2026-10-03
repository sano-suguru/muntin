# Built by scripts/check.sh with only tests/headers_spike.mojo beside it:
# the raw transport must carry headers to a handler the library side has
# never seen (M3-002).
from headers_spike import HRequest, HResponse, Headers, box_raw, raw_args


def signature(var req: HRequest) -> HResponse:
    var sig = req.headers.get("x-signature")
    if not sig:
        return HResponse.text("unsigned", status=401)
    return HResponse.text(sig.value())


def main() raises:
    var h = Headers()
    h.add("X-Signature", "sha256=abc")
    var boxed = box_raw(signature)
    if (
        boxed.invoke(raw_args(HRequest("POST", "/hook", "", h))).body
        != "sha256=abc"
    ):
        raise Error("signature header did not reach the handler")
    if boxed.invoke(raw_args(HRequest("POST", "/hook"))).status != 401:
        raise Error("absent header was not None")
    print("ok")
