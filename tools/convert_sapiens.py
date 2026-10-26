"""Convert Meta's Sapiens body-part segmentation (TorchScript, Goliath's 28 parts) to a Core ML package that gives
the editor's masks directly.

Input: "image" float32 [1,3,H,W] (portrait, 4:3), RGB, raw 0-255 (Sapiens' normalization is baked in).
Output: "masks" [1,5,H/2,W/2], each part's probability: face skin, body skin, lips, clothes, hair (the parts added
up from the 28; the app scales them to the photo).

The exported model only takes 1024 x 768; its parts take any size but the position embedding, which is resized
here (bicubic, as ViTs are fine-tuned at other sizes), so the same weights run at --size (default 768x576: masks
nearly as clean as at 1024, in half the time; 512x384 gets noisy).

usage: python convert_sapiens.py <sapiens torchscript .pt2> <out dir> [--size 768x576] [--check photo.jpg]
"""
import sys, pathlib
import numpy as np, torch, coremltools as ct
import torch.nn.functional as F

# Goliath's parts, in the model's order.
PARTS = ["Background", "Apparel", "Face_Neck", "Hair", "Left_Foot", "Left_Hand", "Left_Lower_Arm", "Left_Lower_Leg",
         "Left_Shoe", "Left_Sock", "Left_Upper_Arm", "Left_Upper_Leg", "Lower_Clothing", "Right_Foot", "Right_Hand",
         "Right_Lower_Arm", "Right_Lower_Leg", "Right_Shoe", "Right_Sock", "Right_Upper_Arm", "Right_Upper_Leg", "Torso",
         "Upper_Clothing", "Lower_Lip", "Upper_Lip", "Lower_Teeth", "Upper_Teeth", "Tongue"]
GROUPS = {
    "face skin": ["Face_Neck"],
    "body skin": ["Left_Foot", "Left_Hand", "Left_Lower_Arm", "Left_Lower_Leg", "Left_Upper_Arm", "Left_Upper_Leg",
                  "Right_Foot", "Right_Hand", "Right_Lower_Arm", "Right_Lower_Leg", "Right_Upper_Arm", "Right_Upper_Leg", "Torso"],
    "lips": ["Lower_Lip", "Upper_Lip"],
    "clothes": ["Apparel", "Upper_Clothing", "Lower_Clothing", "Left_Shoe", "Right_Shoe", "Left_Sock", "Right_Sock"],
    "hair": ["Hair"],
}
MEAN = [123.5, 116.5, 103.5]
STD = [58.5, 57.0, 57.5]


class Resized(torch.nn.Module):
    """The exported model's own parts at another input size."""
    def __init__(self, net, h, w):
        super().__init__()
        self.bb, self.head = net.backbone, net.decode_head
        pos = self.bb.pos_embed.detach().reshape(1, 64, 48, -1).permute(0, 3, 1, 2)
        pos = F.interpolate(pos, size=(h // 16, w // 16), mode="bicubic", align_corners=False)
        self.register_buffer("pos", pos.permute(0, 2, 3, 1).reshape(1, (h // 16) * (w // 16), -1))
        self.gh, self.gw = h // 16, w // 16

    def forward(self, x):
        # The patch embedding's own steps (its forward also returns plain ints, which tracing can't follow).
        t = self.bb.patch_embed.projection(x).flatten(2).transpose(1, 2)
        t = t + self.pos
        for i in range(24):
            t = getattr(self.bb.layers, str(i))(t)
        t = self.bb.ln1(t)
        feat = t.reshape(1, self.gh, self.gw, -1).permute(0, 3, 1, 2)
        h = self.head
        size = (self.gh, self.gw)
        for name, m in h.deconv_layers.named_children():
            if m.original_name == "ConvTranspose2d":
                feat = deconv(feat, m.weight, *size)
                size = (size[0] * 2, size[1] * 2)
            else:
                feat = m(feat)
        return h.conv_seg(h.dropout(h.conv_layers(feat)))


def deconv(x, weight, hh, ww):
    """ConvTranspose2d(kernel 4, stride 2, padding 1, no bias) as four 2 x 2 convolutions, one per output pixel's
    place (row and column even or odd), interleaved: the same numbers, on the GPU (Core ML put the transposed
    convolution on the CPU, which made the GPU no faster than the CPU), with no work spent on zeros.

    Along one axis, output 2i takes inputs i-1, i with taps 3, 1, and output 2i+1 takes inputs i, i+1 with taps 2, 0."""
    c = weight.shape[1]
    k = weight.transpose(0, 1)  # [out, in, 4, 4]
    taps = {0: [3, 1], 1: [2, 0]}
    rows = []
    for a in (0, 1):
        cols = []
        for b in (0, 1):
            sub = k[:, :, taps[a]][:, :, :, taps[b]]
            # Even places reach back one input (padding before), odd ones forward (padding after).
            pad = (1, 0) if b == 0 else (0, 1)
            pad += (1, 0) if a == 0 else (0, 1)
            cols.append(F.conv2d(F.pad(x, pad), sub))
        # Columns interleaved: [.., hh, ww, 2] -> [.., hh, 2ww].
        rows.append(torch.stack(cols, dim=-1).reshape(1, c, hh, 2 * ww))
    # Rows interleaved: [.., hh, 2, 2ww] -> [.., 2hh, 2ww].
    return torch.stack(rows, dim=-2).reshape(1, c, 2 * hh, 2 * ww)


class Masks(torch.nn.Module):
    def __init__(self, net):
        super().__init__()
        self.net = net
        self.register_buffer("mean", torch.tensor(MEAN).view(1, 3, 1, 1))
        self.register_buffer("std", torch.tensor(STD).view(1, 3, 1, 1))
        m = torch.zeros(len(GROUPS), len(PARTS))
        for g, names in enumerate(GROUPS.values()):
            for n in names:
                m[g, PARTS.index(n)] = 1
        self.register_buffer("groups", m)

    def forward(self, x):
        logits = self.net((x - self.mean) / self.std)
        p = torch.softmax(logits, dim=1)
        # [1,28,h,w] -> [1,5,h,w]: each group's parts added up.
        return torch.einsum("gc,bchw->bghw", self.groups, p)


def main():
    src, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
    h, w = map(int, (sys.argv[sys.argv.index("--size") + 1] if "--size" in sys.argv else "768x576").split("x"))
    net = torch.jit.load(str(src), map_location="cpu").eval()
    # The deconvolution rewritten above gives the original's numbers.
    t = torch.randn(1, 1024, 6, 5)
    d0 = getattr(net.decode_head.deconv_layers, "0")
    with torch.no_grad():
        print("deconv rewrite max diff", float((deconv(t, d0.weight, 6, 5) - d0(t)).abs().max()))
    model = Masks(Resized(net, h, w)).eval()
    x = torch.rand(1, 3, h, w) * 255
    with torch.no_grad():
        y = model(x)
        print("output", tuple(y.shape))
        traced = torch.jit.trace(model, x)
    ml = ct.convert(traced, inputs=[ct.TensorType(name="image", shape=(1, 3, h, w))],
                    outputs=[ct.TensorType(name="masks")], minimum_deployment_target=ct.target.macOS15,
                    compute_precision=ct.precision.FLOAT16)
    ml.short_description = f"Sapiens 0.3B body parts (Goliath) at {h}x{w} as five soft masks: face skin, body skin, lips, clothes, hair"
    out.mkdir(parents=True, exist_ok=True)
    path = out / "BodyParts.mlpackage"
    ml.save(str(path))
    print("saved", path)
    if "--check" in sys.argv:
        from PIL import Image
        img = Image.open(sys.argv[sys.argv.index("--check") + 1]).convert("RGB").resize((w, h))
        a = np.asarray(img).astype(np.float32).transpose(2, 0, 1)[None]
        with torch.no_grad():
            ref = model(torch.from_numpy(a)).numpy()
        got = ml.predict({"image": a})["masks"]
        print("max |torch - coreml|", float(np.abs(ref - got).max()))
        for g, name in enumerate(GROUPS):
            print(f"{name:10s} torch {ref[0, g].mean():.3f}  coreml {got[0, g].mean():.3f}")


if __name__ == "__main__":
    main()
