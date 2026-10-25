"""iPhone の話者分離のテスト用の期待値を、自宅サーバと同じ実装 (kaldi-native-fbank / ONNX / sherpa-onnx /
サーバの話者識別のコード) で作る。音声や声は合成したもので、録音は使わない。

    /tmp/coreml-venv/bin/python ios/Tools/make_speaker_fixtures.py \
        --models server/data/models --out ios/OmiKit/Tests/OmiKitTests/Fixtures/speakers.json
(convert_speaker_models.py の環境に kaldi-native-fbank と sherpa-onnx==1.13.8 を加えたもの)
"""

from __future__ import annotations

import argparse
import base64
import json
import sys
from pathlib import Path

import kaldi_native_fbank as knf
import numpy as np
import onnxruntime as ort
import sherpa_onnx as so

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "server"))
from omi_home_server import speaker_model  # noqa: E402
from omi_home_server.speakers import identify  # noqa: E402

SR = 16000


def signal(seconds: float, f0: float, phase: float = 0.0) -> np.ndarray:
    """声に似せた合成音 (基本周波数が揺れる倍音)。Swift のテストと同じ式"""
    t = np.arange(int(seconds * SR), dtype=np.float64) / SR
    inst = f0 * t + 0.5 * np.sin(2 * np.pi * 2.0 * t + phase)
    x = sum(0.12 / k * np.sin(2 * np.pi * k * inst) for k in range(1, 6))
    # すべての帯域に少しだけ音があるように、決まった雑音 (線形合同法) を足す
    noise = np.zeros(len(t))
    state = 7
    for i in range(len(t)):
        state = (state * 1103515245 + 12345) % 2**31
        noise[i] = state / 2**30 - 1
    return (x * (0.6 + 0.4 * np.sin(2 * np.pi * 0.5 * t)) + 0.01 * noise).astype(np.float32)


def fbank(x: np.ndarray) -> np.ndarray:
    o = knf.FbankOptions()
    o.frame_opts.dither = 0
    o.frame_opts.snip_edges = False
    o.mel_opts.num_bins = 80
    o.mel_opts.high_freq = -400
    fb = knf.OnlineFbank(o)
    fb.accept_waveform(SR, (x * 32768).tolist())
    fb.input_finished()
    return np.stack([fb.get_frame(i) for i in range(fb.num_frames_ready)]).astype(np.float32)


def b64(x: np.ndarray, dtype: str) -> str:
    return base64.b64encode(np.ascontiguousarray(x, dtype=dtype).tobytes()).decode()


def lcg_vectors(n: int, d: int, seed: int) -> np.ndarray:
    """Swift でも同じ値を作れる擬似乱数 (線形合同法, -1〜1)"""
    state = seed
    out = np.zeros((n, d), dtype=np.float32)
    for i in range(n):
        for j in range(d):
            state = (state * 1103515245 + 12345) % 2**31
            out[i, j] = np.float32(state / 2**30 - 1)
    return out


class FakeDB:
    def __init__(self, profiles):
        self.p = {k: [v.copy(), w] for k, (v, w) in profiles.items()}
        self.next = -1

    def speaker_profiles(self):
        return [(k, v[0] / np.linalg.norm(v[0]), v[1]) for k, v in self.p.items()]

    def update_speaker_embedding(self, sid, emb, w):
        self.p[sid] = [emb / max(np.linalg.norm(emb), 1e-9), w]

    def create_speaker(self, emb, w):
        sid = self.next
        self.next -= 1
        self.p[sid] = [emb, w]
        return sid

    def replace_segment_speakers(self, seg, rows):
        pass


def matcher_case() -> dict:
    """名前のある 2 人 (学習済み, 白色化あり) + 名前のない声 1 つ。サーバのコードで当てた名前を期待値にする"""
    d = 8
    rng = np.random.default_rng(7)
    centers = {1: np.eye(d)[0], 2: np.eye(d)[1], 3: np.eye(d)[2]}
    names = {1: "自分", 2: "田中", 3: None}
    samples, ys = [], []
    for sid in (1, 2):
        for _ in range(12):
            v = centers[sid] + rng.normal(0, 0.25, d)
            samples.append(v / np.linalg.norm(v))
            ys.append(sid)
    x = np.array(samples)
    y = np.array([0 if s == 1 else 1 for s in ys])
    w = np.ones(len(y))
    mean, proj = speaker_model._wccn(x, y, w)
    z = speaker_model._normalize_rows((x - mean) @ proj)
    cents, _ = speaker_model._centroids(z, y, w, 2)
    model = speaker_model.SpeakerModel([1, 2], cents, np.array([0.55, 0.6]), mean, proj, {}, None, np.array([0.5, 0.55]))
    profiles = {sid: (c / np.linalg.norm(c), 50.0) for sid, c in centers.items()}

    def voice(sid, noise):
        v = (centers[sid] if sid else np.eye(d)[5]) + rng.normal(0, noise, d)
        v = v / np.linalg.norm(v)
        return np.frombuffer(np.asarray(v, "<f2").tobytes(), "<f2").astype(np.float32)  # 保存と同じ半精度

    voices = {"S0": (voice(1, 0.2), 20.0), "S1": (voice(2, 0.2), 8.0), "S2": (voice(3, 0.1), 5.0),
              "S3": (voice(None, 0.1), 4.0), "S4": (voice(None, 0.1), 1.0)}
    utts = [(0.0, 3.0, "S0", voice(1, 0.2)), (3.5, 5.0, "S0", voice(2, 0.1)), (5.5, 7.0, "S1", voice(2, 0.2)),
            (7.2, 8.0, "S1", None), (8.5, 11.0, "S2", voice(3, 0.1)), (11.5, 13.0, "S3", voice(None, 0.1)),
            (13.2, 14.0, "S4", None), (14.5, 17.0, "S2", voice(1, 0.15))]
    db = FakeDB(profiles)
    embs = {k: (v / np.linalg.norm(v), s) for k, (v, s) in voices.items()}
    res = identify(db, "x", embs, match_threshold=0.6, min_seconds=3.0, model=model)
    label_sid = {k: v["speaker_id"] for k, v in res.items()}
    prof = {sid: vec for sid, vec, _ in db.speaker_profiles()}
    for label, (emb, _) in embs.items():
        new, _ = speaker_model.decide_label(model, emb, label_sid.get(label), prof)
        if new is not None:
            label_sid[label] = new
    expected = []
    for s, e, label, emb in utts:
        sid = label_sid.get(label)
        if emb is not None and e - s >= 1.5:
            auto = speaker_model.decide_utterance(model, emb / np.linalg.norm(emb), sid, prof)
            if auto is not None:
                sid = auto
        name = None if sid is None else (names.get(sid) or "その他")
        expected.append({"name": name, "speaker_id": sid if sid is not None and sid > 0 else None})
    return {
        "library": {
            "version": "test", "source": "server", "embedding_model": "test",
            "settings": {"diarization_threshold": 0.3, "match_threshold": 0.6, "min_seconds": 3.0},
            "profiles": [{"id": sid, "name": names[sid], "ignored": False, "weight": 50.0, "vector": b64(v, "<f4")}
                         for sid, (v, _) in profiles.items()],
            "model": {"speaker_ids": [1, 2], "centroids": [b64(c, "<f4") for c in cents],
                      "thresholds": [0.55, 0.6], "review": [0.5, 0.55],
                      "mean": b64(mean, "<f4"), "projection": b64(proj, "<f4")},
        },
        "voices": [{"label": k, "seconds": s, "embedding": b64(v, "<f2")} for k, (v, s) in voices.items()],
        "utterances": [{"start": s, "end": e, "label": label, "embedding": None if emb is None else b64(emb, "<f2")}
                       for s, e, label, emb in utts],
        "expected": expected,
    }


class TrainDB:
    """speaker_model.train が使う DB の操作だけ"""
    def __init__(self, rows, background):
        self.rows, self.background = rows, background

    def named_speakers(self):
        return {1: "A", 2: "B", 3: "C"}

    def all_utterances(self, with_embedding=False):
        return self.rows

    def background_embeddings(self):
        return self.background


def trainer_case(nuisance: float = 0.0, seed: int = 11) -> dict:
    """3 人の声 (確かめた発話と自動の発話、外れた発話を含む) と名前のない声。サーバの train() の結果を期待値にする。
    nuisance: 人によらない声の揺れ (共通の向き)。大きいと白色化 (WCCN) が効く"""
    d = 16
    rng = np.random.default_rng(seed)
    centers = {sid: np.eye(d)[sid] * (0.35 if nuisance else 1) + np.eye(d)[0] + rng.normal(0, 0.05 if nuisance else 0.3, d)
               for sid in (1, 2, 3)}
    direction = rng.normal(0, 1, d)
    direction /= np.linalg.norm(direction)
    samples, rows = [], []
    for sid in (1, 2, 3):
        for i in range(14 if sid != 3 else 6):
            v = centers[sid] + rng.normal(0, 0.35 if not nuisance else 0.08, d) + direction * rng.normal(0, nuisance)
            if i == 13:
                v = rng.normal(0, 1, d)  # 自動で付いた外れ
            v = (v / np.linalg.norm(v)).astype(np.float32)
            manual = i % 3 == 0
            rows.append({"speaker_id": sid, "manual": manual, "label_manual": False, "auto_speaker_id": None, "embedding": v})
            samples.append({"embedding": b64(v, "<f4"), "person": "ABC"[sid - 1], "weight": 3.0 if manual else 1.0,
                            "confirmed": manual})
    background = [(v / np.linalg.norm(v)).astype(np.float32) for v in rng.normal(0, 1, (10, d))]
    model = speaker_model.train(TrainDB(rows, background))
    return {
        "samples": samples,
        "background": [b64(v, "<f4") for v in background],
        "expected": {
            "people": [{1: "A", 2: "B", 3: "C"}[sid] for sid in model.speaker_ids],
            "projection": model.projection is not None,
            "thresholds": [float(t) for t in model.thresholds],
            "review": [float(t) for t in model.review],
            "centroids": [b64(c, "<f4") for c in model.centroids],
            "accuracy": model.info["accuracy"], "evaluated": model.info["evaluated"],
        },
    }


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--models", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    args = ap.parse_args()

    x = signal(2.0, 140.0)
    feats = fbank(x)
    emb = ort.InferenceSession(str(args.models / "wespeaker_en_voxceleb_resnet34_LM.onnx"))
    e = emb.run(None, {"feats": feats[None]})[0][0]
    e2 = emb.run(None, {"feats": fbank(signal(2.0, 230.0, 1.0))[None]})[0][0]

    vectors = lcg_vectors(14, 6, 42)
    cluster = {}
    for t in (0.3, 0.6, 1.0):
        c = so.FastClustering(so.FastClusteringConfig(num_clusters=-1, threshold=t))
        cluster[str(t)] = [int(v) for v in c(np.ascontiguousarray(vectors))]

    fixture = {
        "fbank": {"seconds": 2.0, "f0": 140.0, "frames": int(len(feats)),
                  "rows": {str(i): [round(float(v), 4) for v in feats[i]] for i in (0, 1, 57, len(feats) - 1)}},
        "embedding": {"a": [float(v) for v in e / np.linalg.norm(e)], "b": [float(v) for v in e2 / np.linalg.norm(e2)]},
        "clustering": {"seed": 42, "n": 14, "d": 6, "labels": cluster},
        "matcher": matcher_case(),
        "trainer": trainer_case(),
        "trainer_wccn": trainer_case(nuisance=1.2, seed=5),
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(fixture, ensure_ascii=False, indent=1))
    print("wrote", args.out, "clusters", {k: max(v) + 1 for k, v in cluster.items()},
          "expected names", [x["name"] for x in fixture["matcher"]["expected"]])


if __name__ == "__main__":
    main()
