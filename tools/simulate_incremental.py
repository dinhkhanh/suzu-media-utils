"""Simulate incremental ingest: build groups from the first part of a folder, then classify each later face
as a known person (mean similarity to a group's faces >= assign threshold) or unknown.

Truth is the full-folder reference clustering (see evaluate.py).

usage: python simulate_incremental.py <run> <model> [--split 0.5] [--quality 0.3] [--threshold 0.45]
"""
import sys, numpy as np
sys.path.insert(0, __file__.rsplit("/", 1)[0])
from evaluate import load, cluster, groups_only

args = sys.argv[1:]
def opt(name, default): return float(args[args.index(name) + 1]) if name in args else default
run, model = args[0], args[1]
split, q, th = opt("--split", 0.5), opt("--quality", 0.3), opt("--threshold", 0.45)

keys, e, paths = load(run, model, q)
truth = groups_only(cluster(e, th))
photos = sorted(set(paths))
first = set(photos[: int(len(photos) * split)])
a = np.array([p in first for p in paths])

base = groups_only(cluster(e[a], th))
gids = [g for g in set(base) if g >= 0]
means = np.array([e[a][base == g].mean(0) for g in gids])  # x . mean == mean similarity to the group's faces
# Map each initial group to the truth group most of its faces belong to.
g2t = {g: np.bincount(truth[a][base == g][truth[a][base == g] >= 0] + 1).argmax() - 1 if (truth[a][base == g] >= 0).any() else -1 for g in gids}
known_truth = {g2t[g] for g in gids}

print(f"{model}: {a.sum()} faces in first {len(first)} photos -> {len(gids)} groups; {(~a).sum()} later faces")
for at in [0.35, 0.40, 0.45, 0.50, 0.55]:
    s = e[~a] @ means.T
    best = s.argmax(1); score = s.max(1)
    pred = np.where(score >= at, [g2t[gids[b]] for b in best], -2)
    t = truth[~a]
    is_known = np.array([x in known_truth and x >= 0 for x in t])
    correct = (pred == t) & is_known
    wrong = (pred != -2) & (pred != t)
    print(f"  assign >= {at:.2f}: known-person faces {is_known.sum()}: {correct.sum() / max(1, is_known.sum()):.1%} named instantly, "
          f"{((pred == -2) & is_known).sum()} left for re-cluster; wrong assignments {wrong.sum()} "
          f"({wrong.sum() / len(t):.2%}); new-person faces {(~is_known).sum()}: "
          f"{((pred != -2) & ~is_known).sum()} wrongly matched to a known person")
