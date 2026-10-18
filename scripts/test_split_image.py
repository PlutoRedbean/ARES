import unittest
from split_image import split_image, IROM_BYTES, DRAM_OFFSET, DRAM_BYTES

class SplitImageTest(unittest.TestCase):
    def test_flat_image_gap_is_not_rom(self):
        data = bytearray(DRAM_OFFSET+4)
        data[:8] = bytes.fromhex('1300000093001000')
        data[DRAM_OFFSET:] = bytes.fromhex('78563412')
        rom, ram = split_image(data)
        self.assertEqual(len(rom), IROM_BYTES)
        self.assertEqual(len(ram), DRAM_BYTES)
        self.assertEqual(rom[:8], data[:8])
        self.assertEqual(ram[:4], bytes.fromhex('78563412'))
        self.assertFalse(any(ram[4:]))

    def test_rom_overflow_is_rejected(self):
        with self.assertRaises(ValueError):
            split_image(bytes(IROM_BYTES)+b'\1')

    def test_physical_dram_overflow_is_rejected(self):
        with self.assertRaises(ValueError):
            split_image(bytes(DRAM_OFFSET+DRAM_BYTES+1))

if __name__ == '__main__':
    unittest.main()
