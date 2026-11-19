import sys, time

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass
sys.path.insert(0, ".")
import serial
from host.golden.board_proto import split_stream

CASES = [
    ("手机 13800138000", "mobile"),
    ("13800138000", "mobile"),
    ("手机 138 0013 8000", "mobile"),
    ("身份证 11010519491231002X", "id18"),
    ("身份证 330203300422240391", "id18"),
    ("银行卡 6222020000000000001", "bank"),
    ("联系人王经理", "name"),
    ("刘德华的演唱会在上海", "name"),
    ("请把文件发给杨帆", "name"),
    ("金额还需复核，方向明天再确认", None),
    ("地址：北京市朝阳区建国路88号", "addr"),
    ("订单号 330203300422240391", None),
]
ser = serial.Serial("COM9", 115200, timeout=0.02, write_timeout=5)
time.sleep(0.1)
def send(text):
    ser.reset_input_buffer(); time.sleep(0.02)
    ser.write(text.encode() + b"\n")
    buf = b""; t0 = time.time()
    while time.time() - t0 < 8:
        c = ser.read(512)
        if c:
            buf += c
            if b"mode=" in buf: break
    body, reps = split_stream(buf)
    return body, (reps[0] if reps else {})
for text, field in CASES:
    body, r = send(text)
    got = {k: r.get(k, 0) for k in ("id18","mobile","bank","name","addr")}
    ok = (got[field] > 0) if field else (sum(got.values()) == 0)
    print(("OK  | " if ok else "BAD | ") + text)
    print("      -> " + body.decode("utf-8", "replace").strip())
    print("      n=%s id18=%s mob=%s bank=%s name=%s addr=%s" % (r.get("n"), got["id18"], got["mobile"], got["bank"], got["name"], got["addr"]))
ser.close()