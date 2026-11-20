"""Exercise latest-frame delivery and timeout/recovery without a capture card."""
from threading import Event
from time import monotonic
import unittest
from unittest.mock import patch

from run import Frame, LiveCamera


class Capture(unittest.TestCase):
    def test_stalled_read_then_new_epoch(self):
        camera = LiveCamera(0)
        resume = Event()

        def produce():
            # Producer outruns inference. Only frame 8 is available to consume.
            with camera.changed:
                for n in range(9):
                    camera.frame = Frame(n, monotonic() - camera.origin, object())
                camera.changed.notify()
            resume.wait(1)
            with camera.changed:
                camera.epoch += 1
                camera.frame = Frame(9, monotonic() - camera.origin, object(), camera.epoch)
                camera.changed.notify()

        with patch('run.VIDEO_TIMEOUT', 0.025), patch.object(camera, 'capture', produce):
            frames = camera.frames()
            try:
                first = next(frames)
                self.assertEqual(first.number, 8)
                self.assertTrue(camera.is_current(first))
                self.assertIsNone(next(frames))
                self.assertFalse(camera.is_current(first))
                resume.set()
                current = next(frames)
                self.assertEqual((current.number, current.epoch), (9, 1))
                self.assertFalse(camera.is_current(first))
            finally:
                resume.set()
                frames.close()


if __name__ == "__main__":
    unittest.main()
