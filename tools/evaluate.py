"""Compare facescan runs without ground truth.

The reference clustering (ArcFace, hi-res crops) was checked by eye; other variants are scored by how well they
agree with it, and by how cleanly they separate its groups.

usage: python evaluate.py <ref_run> <ref_model> <run:model>... [--quality 0.3] [--threshold name=value ...]
"""
import json, sys, pathlib, numpy as np
from scipy.cluster.hierarchy import linkage, fcluster
from sklearn.metrics import adjusted_rand_score

def load(run, model, quality, min_size=40):
    run = pathlib.Path(run)
    scan = json.loads((run / "scan.json").read_text())
    faces = [f for f in scan["faces"] if f.get("alignedFrom")]
    d = scan["models"][model]
    e = np.fromfile(run / f"emb_{model}.f32", dtype=np.float32).reshape(-1, d)
    keep = [i for i, f in enumerate(faces) if f["face"]["w"] >= min_size and (f["face"].get("quality") or 0) >= quality]
    keys = [(scan["photos"][faces[i]["photo"]]["path"], round(faces[i]["face"]["x"]), round(faces[i]["face"]["y"])) for i in keep]
    return keys, e[keep], [scan["photos"][faces[i]["photo"]]["path"] for i in keep]

def cluster(e, threshold):
    if len(e) < 2: return np.zeros(len(e), int)
    z = linkage(e, method="average", metric="cosine")
    return fcluster(z, t=1 - threshold, criterion="distance")

def groups_only(labels, min_size=3):
    """Faces in clusters smaller than min_size become unassigned (-1), like the app."""
    u, c = np.unique(labels, return_counts=True)
    small = set(u[c < min_size])
    return np.array([-1 if l in small else l for l in labels])

if __name__ == "__main__":
    args = sys.argv[1:]
    q = float(args[args.index("--quality") + 1]) if "--quality" in args else 0.3
    th = {"ArcFaceR50": 0.45, "SFace": 0.45}
    for a in args:
        if "=" in a and not a.startswith("--"): k, v = a.split("="); th[k] = float(v)
    pos = [a for a in args if not a.startswith("--") and "=" not in a and not a.replace(".", "").isdigit()]
    ref_run, ref_model, variants = pos[0], pos[1], pos[2:]

    rk, re_, _ = load(ref_run, ref_model, q)
    ref = groups_only(cluster(re_, th[ref_model]))
    print(f"reference {ref_run}:{ref_model} @ {th[ref_model]}: {len(rk)} faces, {len(set(ref) - {-1})} groups")

    for v in variants:
        run, model = v.split(":")
        k, e, _ = load(run, model, q)
        idx = {key: i for i, key in enumerate(k)}
        common = [i for i, key in enumerate(rk) if key in idx]
        E = e[[idx[rk[i]] for i in common]]
        R = ref[common]
        lab = groups_only(cluster(E, th[model]))
        S = E @ E.T
        same = (R[:, None] == R[None, :]) & (R[:, None] >= 0)
        diff = (R[:, None] != R[None, :]) & (R[:, None] >= 0) & (R[None, :] >= 0)
        iu = np.triu_indices(len(R), 1)
        w, b = S[iu][same[iu]], S[iu][diff[iu]]
        # Separation margin: how far the 5th percentile of same-person pairs sits above the 99.9th of different-person pairs.
        print(f"  {run}:{model} @ {th[model]}: {len(set(lab) - {-1})} groups, ARI vs ref {adjusted_rand_score(R, lab):.3f}; "
              f"same-person sim median {np.median(w):.2f} (p5 {np.percentile(w, 5):.2f}), "
              f"different-person median {np.median(b):.2f} (p99.9 {np.percentile(b, 99.9):.2f}), "
              f"margin {np.percentile(w, 5) - np.percentile(b, 99.9):+.2f}")
