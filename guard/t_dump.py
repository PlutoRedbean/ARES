import sys
sys.path.insert(0, ".")
import serial, time
from host.golden.board_proto import split_stream
s = "我是马嘉祺"
data = s.encode() + bytes([10])
ser = serial.Serial("COM9", 115200, timeout=0.05, write_timeout=5)
time.sleep(0.1)
ser.reset_input_buffer()
ser.write(data)
buf = b""
t0 = time.time()
while time.time() - t0 < 8:
    c = ser.read(512)
    if c:
        buf += c
        if b"mode=" in buf:
            break
ser.close()
text, reps = split_stream(buf)
print("sent_len", len(data))
print("body_len", len(text))
print("sent_hex", data.hex(" "))
print("body_hex", text.hex(" "))