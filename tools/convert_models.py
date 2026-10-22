"""Convert face-embedding ONNX models to Core ML packages.

Input: float32 [N,3,112,112], RGB, raw 0-255 (normalization is baked in).
Output: "embedding" float32 [N,D], L2-normalized.

usage: python convert_models.py <dl_dir> <out_dir>
"""
import sys, pathlib
import numpy as np, torch, onnx, onnxruntime as ort, coremltools as ct
from onnx2torch import convert

dl, out = map(pathlib.Path, sys.argv[1:3])

MODELS = {
    # name: (onnx path, mean, std)
    "ArcFaceR50": (dl / "buffalo_l/w600k_r50.onnx", 127.5, 127.5),
    "SFace": (dl / "sface.onnx", 0.0, 1.0),
}

BATCHES = [1, 16]

class Wrapped(torch.nn.Module):
    def __init__(self, net, mean, std):
        super().__init__()
        self.net, self.mean, self.std = net, mean, std
    def forward(self, x):
        y = self.net((x - self.mean) / self.std)
        # Not F.normalize: its expand_as lowers to dynamic shape ops that push the whole graph onto the CPU.
        return y * torch.rsqrt((y * y).sum(1, keepdim=True) + 1e-12)

for name, (path, mean, std) in MODELS.items():
    net = convert(onnx.load(str(path))).eval()
    model = Wrapped(net, mean, std).eval()
    x = torch.rand(4, 3, 112, 112) * 255
    with torch.no_grad():
        traced = torch.jit.trace(model, x)
    ml = ct.convert(
        traced,
        # Enumerated (not ranged) batch sizes: a RangeDim input keeps Core ML off the Neural Engine.
        inputs=[ct.TensorType(name="image", shape=ct.EnumeratedShapes(
            shapes=[(b, 3, 112, 112) for b in BATCHES], default=(BATCHES[-1], 3, 112, 112)))],
        outputs=[ct.TensorType(name="embedding")],
        minimum_deployment_target=ct.target.macOS15,
        compute_precision=ct.precision.FLOAT16,
    )
    dst = out / f"{name}.mlpackage"
    ml.save(str(dst))

    # Check against onnxruntime on the same inputs.
    sess = ort.InferenceSession(str(path))
    inp = sess.get_inputs()[0].name
    xn = ((x.numpy() - mean) / std).astype(np.float32)
    ref = np.concatenate([sess.run(None, {inp: xn[i:i + 1]})[0] for i in range(len(xn))])
    ref /= np.linalg.norm(ref, axis=1, keepdims=True)
    got = np.concatenate([ml.predict({"image": x.numpy()[i:i + 1]})["embedding"] for i in range(len(xn))])
    cos = (ref * got).sum(1)
    print(f"{name}: dim={got.shape[1]} cos vs onnx min={cos.min():.5f} mean={cos.mean():.5f} -> {dst}")
