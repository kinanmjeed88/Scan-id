"""Clean-room two-stage local document & ID-card boundary neural architecture.

Stage 1 (`ScanIdStage1Detector`):
  Input:  `input` float32 [B, 3, 160, 160] RGB normalized to [0, 1].
  Output:
    - `dense_map`  float32 [B, 11, 40, 40]:
        ch 0:    center_prob (Sigmoid) — peak per distinct document/card
        ch 1:    shrunk_mask (Sigmoid) — 0.78x eroded interior for multi-card separation
        ch 2:    full_mask   (Sigmoid) — full quadrilateral mask
        ch 3..10: quad_offsets (Linear) — 4x (dx, dy) clockwise corner offsets from cell center
    - `scene_prob` float32 [B, 2] (Sigmoid):
        [0]: has_document, [1]: is_multi_document

Stage 2 (`ScanIdStage2CornerRefiner`):
  Input:  `input` float32 [B, 3, 128, 128] RGB ROI crop normalized to [0, 1].
  Output:
    - `corner_heatmaps` float32 [B, 5, 64, 64] (Sigmoid):
        ch 0..3: TL, TR, BR, BL corner probability heatmaps (stride 2)
        ch 4:    outer physical 4-edge perimeter probability map
    - `corner_offsets`  float32 [B, 8, 64, 64] (Tanh * 0.5):
        subpixel (dx, dy) cell offsets for TL, TR, BR, BL
    - `roi_quality`     float32 [B, 3] (Sigmoid):
        [0]: valid_complete_document (all 4 corners inside ROI & real document)
        [1]: all_four_corners_visible
        [2]: surface_clarity

Only standard ONNX Opset-13 operators (`Conv`, `Relu`, `Sigmoid`, `Tanh`, `Mul`,
`Add`, `Resize`, `ReduceMean`, `Gemm` / `MatMul`) are emitted after BatchNorm
folding so the exact `.onnx` binaries execute identically in ONNX Runtime and in
Scan-id's cross-platform pure-Dart ONNX inference engine.
"""

from __future__ import annotations

import copy
import torch
import torch.nn as nn
import torch.nn.functional as F


class ConvBNReLU(nn.Module):
    def __init__(
        self,
        in_ch: int,
        out_ch: int,
        kernel_size: int = 3,
        stride: int = 1,
        padding: int | None = None,
        groups: int = 1,
        act: bool = True,
    ) -> None:
        super().__init__()
        if padding is None:
            padding = kernel_size // 2
        self.conv = nn.Conv2d(
            in_ch,
            out_ch,
            kernel_size=kernel_size,
            stride=stride,
            padding=padding,
            groups=groups,
            bias=False,
        )
        self.bn = nn.BatchNorm2d(out_ch)
        self.act = nn.ReLU(inplace=False) if act else nn.Identity()

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return self.act(self.bn(self.conv(x)))


class DSBlock(nn.Module):
    """Depthwise-separable block with optional residual connection."""

    def __init__(
        self,
        in_ch: int,
        out_ch: int,
        kernel_size: int = 3,
        stride: int = 1,
    ) -> None:
        super().__init__()
        self.use_res = stride == 1 and in_ch == out_ch
        self.dw = ConvBNReLU(
            in_ch,
            in_ch,
            kernel_size=kernel_size,
            stride=stride,
            groups=in_ch,
            act=True,
        )
        self.pw = ConvBNReLU(
            in_ch,
            out_ch,
            kernel_size=1,
            stride=1,
            padding=0,
            act=True,
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        y = self.pw(self.dw(x))
        return x + y if self.use_res else y


class ScanIdStage1Detector(nn.Module):
    """Multi-document instance + coarse quad detector at 160x160 -> 40x40."""

    input_size = 160
    grid_size = 40

    def __init__(self) -> None:
        super().__init__()
        self.stem = ConvBNReLU(3, 20, kernel_size=3, stride=2)  # 80x80
        self.b1 = DSBlock(20, 28, kernel_size=3, stride=1)  # 80x80
        self.b2a = DSBlock(28, 44, kernel_size=3, stride=2)  # 40x40 (P2)
        self.b2b = DSBlock(44, 44, kernel_size=3, stride=1)
        self.b3a = DSBlock(44, 72, kernel_size=5, stride=2)  # 20x20 (P3)
        self.b3b = DSBlock(72, 72, kernel_size=5, stride=1)
        self.b4a = DSBlock(72, 104, kernel_size=5, stride=2)  # 10x10 (P4)
        self.b4b = DSBlock(104, 104, kernel_size=5, stride=1)
        self.b5a = DSBlock(104, 136, kernel_size=5, stride=2)  # 5x5   (P5)
        self.b5b = DSBlock(136, 136, kernel_size=3, stride=1)

        # Top-down FPN to 40x40 with 48 channels
        fpn_ch = 48
        self.lat5 = ConvBNReLU(136, fpn_ch, kernel_size=1, padding=0)
        self.lat4 = ConvBNReLU(104, fpn_ch, kernel_size=1, padding=0)
        self.lat3 = ConvBNReLU(72, fpn_ch, kernel_size=1, padding=0)
        self.lat2 = ConvBNReLU(44, fpn_ch, kernel_size=1, padding=0)

        self.smooth4 = DSBlock(fpn_ch, fpn_ch, kernel_size=3, stride=1)
        self.smooth3 = DSBlock(fpn_ch, fpn_ch, kernel_size=3, stride=1)
        self.smooth2 = DSBlock(fpn_ch, fpn_ch, kernel_size=3, stride=1)

        # Separate branches for segmentation/center vs offset regression
        self.cls_tower = nn.Sequential(
            DSBlock(fpn_ch, fpn_ch, kernel_size=3, stride=1),
            DSBlock(fpn_ch, fpn_ch, kernel_size=3, stride=1),
        )
        self.reg_tower = nn.Sequential(
            DSBlock(fpn_ch, fpn_ch, kernel_size=3, stride=1),
            DSBlock(fpn_ch, fpn_ch, kernel_size=3, stride=1),
        )
        self.mask_head = nn.Conv2d(fpn_ch, 3, kernel_size=1, bias=True)
        # 4 rotation-continuous instance bbox extent offsets: [xmin - cx, ymin - cy, xmax - cx, ymax - cy]
        self.offset_head = nn.Conv2d(fpn_ch, 4, kernel_size=1, bias=True)

        # Global scene classifier
        self.scene_fc1 = nn.Linear(136, 40)
        self.scene_act = nn.ReLU(inplace=False)
        self.scene_fc2 = nn.Linear(40, 2)

        self._init_weights()

    def _init_weights(self) -> None:
        for m in self.modules():
            if isinstance(m, nn.Conv2d):
                nn.init.kaiming_normal_(m.weight, mode="fan_out", nonlinearity="relu")
                if m.bias is not None:
                    nn.init.zeros_(m.bias)
            elif isinstance(m, nn.BatchNorm2d):
                nn.init.ones_(m.weight)
                nn.init.zeros_(m.bias)
            elif isinstance(m, nn.Linear):
                nn.init.kaiming_normal_(m.weight, nonlinearity="relu")
                if m.bias is not None:
                    nn.init.zeros_(m.bias)
        # Prior bias -2.19 (~0.10 probability) for center/mask focal stability
        nn.init.constant_(self.mask_head.bias, -2.19)

    def forward(self, x: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor]:
        s1 = self.b1(self.stem(x))
        p2 = self.b2b(self.b2a(s1))
        p3 = self.b3b(self.b3a(p2))
        p4 = self.b4b(self.b4a(p3))
        p5 = self.b5b(self.b5a(p4))

        f5 = self.lat5(p5)
        f4 = self.smooth4(
            self.lat4(p4) + F.interpolate(f5, scale_factor=2.0, mode="nearest")
        )
        f3 = self.smooth3(
            self.lat3(p3) + F.interpolate(f4, scale_factor=2.0, mode="nearest")
        )
        f2 = self.smooth2(
            self.lat2(p2) + F.interpolate(f3, scale_factor=2.0, mode="nearest")
        )

        masks = torch.sigmoid(self.mask_head(self.cls_tower(f2)))
        offsets = torch.tanh(self.offset_head(self.reg_tower(f2))) * 1.15
        dense_map = torch.cat([masks, offsets], dim=1)

        pooled = p5.mean(dim=(2, 3))
        scene_prob = torch.sigmoid(self.scene_fc2(self.scene_act(self.scene_fc1(pooled))))
        return dense_map, scene_prob


class ScanIdStage2CornerRefiner(nn.Module):
    """ROI 4-corner heatmap + subpixel offset + boundary edge + validity network."""

    input_size = 128
    grid_size = 64

    def __init__(self) -> None:
        super().__init__()
        self.stem = ConvBNReLU(3, 24, kernel_size=3, stride=2)  # 64x64
        self.b1a = DSBlock(24, 32, kernel_size=3, stride=1)  # 64x64 (P1)
        self.b1b = DSBlock(32, 32, kernel_size=3, stride=1)

        self.b2a = DSBlock(32, 56, kernel_size=3, stride=2)  # 32x32 (P2)
        self.b2b = DSBlock(56, 56, kernel_size=3, stride=1)

        self.b3a = DSBlock(56, 88, kernel_size=5, stride=2)  # 16x16 (P3)
        self.b3b = DSBlock(88, 88, kernel_size=5, stride=1)

        self.b4a = DSBlock(88, 120, kernel_size=5, stride=2)  # 8x8   (P4)
        self.b4b = DSBlock(120, 120, kernel_size=5, stride=1)

        self.b5a = DSBlock(120, 152, kernel_size=5, stride=2)  # 4x4   (P5)
        self.b5b = DSBlock(152, 152, kernel_size=3, stride=1)

        fpn_ch = 44
        self.lat5 = ConvBNReLU(152, fpn_ch, kernel_size=1, padding=0)
        self.lat4 = ConvBNReLU(120, fpn_ch, kernel_size=1, padding=0)
        self.lat3 = ConvBNReLU(88, fpn_ch, kernel_size=1, padding=0)
        self.lat2 = ConvBNReLU(56, fpn_ch, kernel_size=1, padding=0)
        self.lat1 = ConvBNReLU(32, fpn_ch, kernel_size=1, padding=0)

        self.smooth4 = DSBlock(fpn_ch, fpn_ch, kernel_size=3, stride=1)
        self.smooth3 = DSBlock(fpn_ch, fpn_ch, kernel_size=3, stride=1)
        self.smooth2 = DSBlock(fpn_ch, fpn_ch, kernel_size=3, stride=1)
        self.smooth1 = DSBlock(fpn_ch, fpn_ch, kernel_size=3, stride=1)

        self.hmap_tower = nn.Sequential(
            DSBlock(fpn_ch, fpn_ch, kernel_size=3, stride=1),
            DSBlock(fpn_ch, fpn_ch, kernel_size=3, stride=1),
        )
        self.off_tower = nn.Sequential(
            DSBlock(fpn_ch, fpn_ch, kernel_size=3, stride=1),
        )

        # ch 0..3: TL, TR, BR, BL | ch 4: rotation-invariant any_corner | ch 5: boundary_edge
        self.hmap_head = nn.Conv2d(fpn_ch, 6, kernel_size=1, bias=True)
        # ch 0..1: shared subpixel (dx, dy) offset at every corner peak
        self.off_head = nn.Conv2d(fpn_ch, 2, kernel_size=1, bias=True)

        # Global validity head uses both deepest semantic P5 and border-aware max/mean
        self.val_fc1 = nn.Linear(152, 48)
        self.val_act = nn.ReLU(inplace=False)
        self.val_fc2 = nn.Linear(48, 3)

        self._init_weights()

    def _init_weights(self) -> None:
        for m in self.modules():
            if isinstance(m, nn.Conv2d):
                nn.init.kaiming_normal_(m.weight, mode="fan_out", nonlinearity="relu")
                if m.bias is not None:
                    nn.init.zeros_(m.bias)
            elif isinstance(m, nn.BatchNorm2d):
                nn.init.ones_(m.weight)
                nn.init.zeros_(m.bias)
            elif isinstance(m, nn.Linear):
                nn.init.kaiming_normal_(m.weight, nonlinearity="relu")
                if m.bias is not None:
                    nn.init.zeros_(m.bias)
        nn.init.constant_(self.hmap_head.bias, -2.5)

    def forward(
        self, x: torch.Tensor
    ) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
        p1 = self.b1b(self.b1a(self.stem(x)))
        p2 = self.b2b(self.b2a(p1))
        p3 = self.b3b(self.b3a(p2))
        p4 = self.b4b(self.b4a(p3))
        p5 = self.b5b(self.b5a(p4))

        f5 = self.lat5(p5)
        f4 = self.smooth4(
            self.lat4(p4) + F.interpolate(f5, scale_factor=2.0, mode="nearest")
        )
        f3 = self.smooth3(
            self.lat3(p3) + F.interpolate(f4, scale_factor=2.0, mode="nearest")
        )
        f2 = self.smooth2(
            self.lat2(p2) + F.interpolate(f3, scale_factor=2.0, mode="nearest")
        )
        f1 = self.smooth1(
            self.lat1(p1) + F.interpolate(f2, scale_factor=2.0, mode="nearest")
        )

        corner_heatmaps = torch.sigmoid(self.hmap_head(self.hmap_tower(f1)))
        corner_offsets = torch.tanh(self.off_head(self.off_tower(f1))) * 0.5
        pooled = p5.mean(dim=(2, 3))
        roi_quality = torch.sigmoid(self.val_fc2(self.val_act(self.val_fc1(pooled))))
        return corner_heatmaps, corner_offsets, roi_quality


class AdaptiveWingLoss(nn.Module):
    """Adaptive Wing Loss (Wang et al., ICCV 2019) for sharp heatmap peaks."""

    def __init__(
        self,
        omega: float = 14.0,
        theta: float = 0.5,
        epsilon: float = 1.0,
        alpha: float = 2.1,
        fg_weight: float = 10.0,
    ) -> None:
        super().__init__()
        self.omega = omega
        self.theta = theta
        self.epsilon = epsilon
        self.alpha = alpha
        self.fg_weight = fg_weight

    def forward(self, pred: torch.Tensor, target: torch.Tensor) -> torch.Tensor:
        delta = (target - pred).abs()
        a_exp = self.alpha - target
        A = (
            self.omega
            * (1.0 / (1.0 + torch.pow(self.theta / self.epsilon, a_exp)))
            * a_exp
            * torch.pow(self.theta / self.epsilon, a_exp - 1.0)
            * (1.0 / self.epsilon)
        )
        C = self.theta * A - self.omega * torch.log(
            1.0 + torch.pow(self.theta / self.epsilon, a_exp)
        )
        small = self.omega * torch.log(
            1.0 + torch.pow(delta / self.epsilon, a_exp)
        )
        large = A * delta - C
        loss = torch.where(delta < self.theta, small, large)
        weights = torch.where(target > 0.05, self.fg_weight, 1.0)
        return (loss * weights).mean()


def fuse_conv_bn_eval(conv: nn.Conv2d, bn: nn.BatchNorm2d) -> nn.Conv2d:
    """Fold an eval-mode BatchNorm2d analytically into Conv2d."""
    fused = nn.Conv2d(
        conv.in_channels,
        conv.out_channels,
        kernel_size=conv.kernel_size,
        stride=conv.stride,
        padding=conv.padding,
        dilation=conv.dilation,
        groups=conv.groups,
        bias=True,
    )
    w = conv.weight.data.clone()
    b = (
        conv.bias.data.clone()
        if conv.bias is not None
        else torch.zeros(conv.out_channels, dtype=w.dtype, device=w.device)
    )
    inv_std = bn.weight.data / torch.sqrt(bn.running_var.data + bn.eps)
    fused.weight.data = w * inv_std.reshape(-1, 1, 1, 1)
    fused.bias.data = (b - bn.running_mean.data) * inv_std + bn.bias.data
    return fused


def fuse_model_for_export(model: nn.Module) -> nn.Module:
    """Return a deep copy of `model` in eval mode with all ConvBNReLU fused."""
    exported = copy.deepcopy(model).eval()
    for module in exported.modules():
        if isinstance(module, ConvBNReLU) and isinstance(module.bn, nn.BatchNorm2d):
            module.conv = fuse_conv_bn_eval(module.conv, module.bn)
            module.bn = nn.Identity()
    return exported
