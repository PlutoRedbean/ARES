#!/usr/bin/env python3
"""Exercise real serial commands plus terminal mode restoration (no MMIO input injection)."""
from pathlib import Path
import os
import pty
import re
import select
import subprocess
import termios
import time

root = Path(__file__).resolve().parents[1]
runner = root / 'build/rtos_shell/model/run'
commands = ('help\nps\ntick\nirq\nled 1\nled 0\nled 2\n'
            'echo "hello ARES" test\necho hellp\bo\nti\t\n'
            'sleep 3\nsleep nope\necall\nunknown_cmd\n\nquit\n')
result = subprocess.run([str(runner), '--max-ms', '500'], input=commands,
                        text=True, capture_output=True, cwd=root, timeout=90, check=True)
text = result.stdout.replace('\r', '')
for expected in ('RT-Thread shell commands:', 'tshell', 'tidle', 'led=1', 'led=0',
                 'usage: led 0|1', 'hello ARES test', '\nhello\n', 'slept 3 ms',
                 'usage: sleep 0..60000', 'ecall PASS', 'unknown_cmd: command not found.',
                 'ARES SHELL EXIT'):
    assert expected in text, (expected, text)
assert len(re.findall(r'tick=\d+ ms=\d+', text)) == 2, 'tick command and TAB completion'
(root / 'build/rtos_shell/commands.log').write_text(text)

# Physical UART burst, without simulator mailbox pacing: catches RX character loss.
burst = 'echo ' + 'a'*64 + '\nquit\n'
result = subprocess.run([str(runner), '--burst', '--max-ms', '100'], input=burst,
                        text=True, capture_output=True, cwd=root, timeout=30, check=True)
assert '\n'+'a'*64+'\n' in result.stdout.replace('\r', '')
assert 'ARES SHELL EXIT' in result.stdout
(root / 'build/rtos_shell/burst.log').write_text(result.stdout)

# A real TTY uses raw keyboard input, and must be restored after Ctrl-C.
master, slave = pty.openpty()
saved = termios.tcgetattr(slave)
process = subprocess.Popen([str(runner)], stdin=slave, stdout=slave, stderr=slave, cwd=root)
output = b''
try:
    deadline = time.monotonic()+30
    while b'msh >' not in output and time.monotonic()<deadline:
        if select.select([master], [], [], 0.2)[0]:
            output += os.read(master, 4096)
    assert b'msh >' in output, output
    os.write(master, b'echo tty-input\r')
    deadline = time.monotonic()+15
    while b'\r\ntty-input\r\n' not in output and time.monotonic()<deadline:
        if select.select([master], [], [], 0.2)[0]:
            output += os.read(master, 4096)
    assert b'\r\ntty-input\r\n' in output, output
    os.write(master, b'\x03')
    assert process.wait(timeout=5) == 0
    assert termios.tcgetattr(slave) == saved, 'terminal settings not restored'
finally:
    if process.poll() is None:
        process.terminate()
        process.wait(timeout=5)
    os.close(master)
    os.close(slave)
print('SHELL PASS: UART commands, ps, invalid input, quoting, backspace, TAB, continuous RX burst, TTY and Ctrl-C restore')
