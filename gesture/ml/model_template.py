"""ScreenSense - hardware-matched detector template.

Train this architecture (or keep these shapes) and the weights drop straight
into the FPGA pipeline.  See docs/MODEL.md for the hard constraints.
"""

import torch
import torch.nn as nn


def conv(cin, cout, k, s=1):
    return nn.Conv2d(cin, cout, k, stride=s, padding=(k // 2), bias=True)


class MundusDet(nn.Module):
    """11-layer single-scale detector: 1280x720x3 -> 80x45xK.

    Only conv / ReLU.  No BatchNorm, no LeakyReLU, no upsample, no residual.
    The two heads (head_a from L6, head_b from L8/L9) each output K scores
    per grid cell; the hardware takes the argmax across all channels.
    """

    def __init__(self, num_classes: int = 4):
        super().__init__()
        self.l0  = conv(3, 8, 3, 2)
        self.l1  = conv(8, 16, 3, 2)
        self.l2  = conv(16, 32, 3, 2)
        self.l3  = conv(32, 64, 3, 2)
        self.l4  = conv(64, 64, 3, 1)
        self.l5  = conv(64, 32, 3, 1)
        self.l6  = conv(32, 32, 3, 1)
        self.l7  = conv(32, num_classes, 1, 1)   # head A
        self.l8  = conv(64, 32, 3, 1)            # branch from l4
        self.l9  = conv(32, 32, 3, 1)
        self.l10 = conv(32, num_classes, 1, 1)   # head B

    def forward(self, x):
        x = torch.relu(self.l0(x))
        x = torch.relu(self.l1(x))
        x = torch.relu(self.l2(x))
        x = torch.relu(self.l3(x))
        f4 = torch.relu(self.l4(x))
        x = torch.relu(self.l5(f4))
        x = torch.relu(self.l6(x))
        head_a = self.l7(x)
        y = torch.relu(self.l8(f4))
        y = torch.relu(self.l9(y))
        head_b = self.l10(y)
        return head_a, head_b


def heatmap_target(centers, grid_h=45, grid_w=80, num_classes=4, sigma=0.0):
    """Build the per-cell classification target the hardware expects.

    centers: list of (cls, x, y) in pixel coordinates.
    sigma=0 -> hard one-hot cell; sigma>0 -> gaussian blob (training aid only,
    the hardware argmax still takes the peak).
    """
    import math
    t = torch.zeros(1, num_classes, grid_h, grid_w)
    for cls, px, py in centers:
        gx = min(grid_w - 1, max(0, int(px) * grid_w // 1280))
        gy = min(grid_h - 1, max(0, int(py) * grid_h // 720))
        if sigma <= 0:
            t[0, cls, gy, gx] = 1.0
        else:
            for yy in range(grid_h):
                for xx in range(grid_w):
                    d2 = (xx - gx) ** 2 + (yy - gy) ** 2
                    v = math.exp(-d2 / (2 * sigma * sigma))
                    t[0, cls, yy, xx] = max(t[0, cls, yy, xx], v)
    return t


if __name__ == "__main__":
    m = MundusDet(num_classes=4)
    x = torch.zeros(1, 3, 720, 1280)
    a, b = m(x)
    print("head_a", tuple(a.shape), "head_b", tuple(b.shape))
    print("params", sum(p.numel() for p in m.parameters()))
