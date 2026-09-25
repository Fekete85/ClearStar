#!/usr/bin/env python3
"""Stand-in for the StarNet2 command-line program in the tests: the same arguments and --machine-progress
output; it "removes" the stars by clipping every value above STUB_CLIP (default 1.0 = no change) and, like
the real StarNet2, writes a colour FITS cube in BGR plane order. STUB_FAIL=1 makes it fail like StarNet2."""
import json, os, struct, sys

args = sys.argv[1:]
inp = args[args.index("--input") + 1]
out = args[args.index("--output") + 1]
if os.environ.get("STUB_FAIL"):
    print(json.dumps({"event": "error", "message": "stub failure"}, separators=(",", ":")), file=sys.stderr, flush=True)
    sys.exit(3)
data = open(inp, "rb").read()
header_end = 0
while True:
    block = data[header_end:header_end + 2880]
    header_end += 2880
    if any(block[i:i + 80].startswith(b"END ") or block[i:i + 80].rstrip() == b"END" for i in range(0, 2880, 80)):
        break
header = data[:header_end]
def key(name):
    for i in range(0, len(header), 80):
        card = header[i:i + 80].decode("ascii")
        if card.startswith(name.ljust(8) + "="):
            return int(card[10:].split("/")[0].strip())
    return 1
w, h = key("NAXIS1"), key("NAXIS2")
naxis = key("NAXIS")
planes = key("NAXIS3") if naxis == 3 else 1
n = w * h
clip = float(os.environ.get("STUB_CLIP", "1.0"))
values = list(struct.unpack(">%df" % (n * planes), data[header_end:header_end + n * planes * 4]))
for step in range(1, 5):
    print(json.dumps({"event": "progress", "percent": step * 25}, separators=(",", ":")), file=sys.stderr, flush=True)
values = [min(v, clip) for v in values]
if planes == 3:
    values = values[2 * n:3 * n] + values[n:2 * n] + values[0:n]
body = struct.pack(">%df" % len(values), *values)
body += b"\0" * ((2880 - len(body) % 2880) % 2880)
open(out, "wb").write(header + body)
