# The same members, all present, read by a plain JsonFields struct.
from std.sys import argv
from std.time import perf_counter_ns
from muntin import Json, JsonFields


@fieldwise_init
struct Q(JsonFields):
    var text: String
    var limit: Int
    var ratio: Float64
    var on: Bool
    var flags: List[String]


def main() raises:
    var n = Int(argv()[1])
    var body = String('{"text":"q","limit":20,"ratio":0.5,"on":true,"flags":["a","b"]}')
    var sink = 0
    var t = perf_counter_ns()
    for _ in range(n):
        var q = Json[Q].from_body(body).take()
        sink += q.limit + len(q.flags)
    var dt = perf_counter_ns() - t
    print("plain ns/op", Float64(dt) / Float64(n), "sink", sink)
