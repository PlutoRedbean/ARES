#!/usr/bin/env python3
"""Split the riscv32-ares flat image by physical address, never by file size.

IROM: image[0:32KiB]; DRAM: image[1MiB:1MiB+256KiB]. The address gap
must contain zeros. Output hex files are little-endian 64/32-bit words for
registered IROM_BMEM/BRAM simulation models.
"""
import argparse
from pathlib import Path
IROM_BYTES = 32 * 1024
DRAM_OFFSET = 0x100000
DRAM_BYTES = 256 * 1024


def split_image(data):
    if len(data) > DRAM_OFFSET + DRAM_BYTES:
        raise ValueError('image exceeds the 256KiB physical DRAM window')
    if any(data[IROM_BYTES:DRAM_OFFSET]):
        raise ValueError('nonzero bytes outside the 32KiB IROM and DRAM windows')
    return (data[:IROM_BYTES].ljust(IROM_BYTES, b'\0'),
            data[DRAM_OFFSET:].ljust(DRAM_BYTES, b'\0'))


def write_hex(data, width, path):
    path.write_text(''.join(f'{int.from_bytes(data[i:i+width], "little"):0{width*2}x}\n'
                            for i in range(0, len(data), width)))


def emit_image(source, output):
    irom, dram = split_image(Path(source).read_bytes())
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    write_hex(irom, 8, output/'irom.hex')
    write_hex(dram, 4, output/'dram.hex')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('image', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    emit_image(args.image, args.output)
