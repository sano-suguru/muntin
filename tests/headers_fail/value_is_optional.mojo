# Must not compile (M3-002): `get` returns `Optional[String]`, so an absent
# field and an empty value are different, unlike a backend `get` that
# returns "" for both; the caller unwraps it explicitly.
# Expected diagnostic (checked by scripts/check.sh): cannot implicitly convert 'Optional[String]' value to 'String'
from headers_spike import Headers


def signature(h: Headers) -> String:
    return h.get("X-Signature")


def main():
    print(signature(Headers()))
