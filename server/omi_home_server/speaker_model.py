"""名前を付けた話者の声を学習し、次からの話者の割り当てと「その人らしくない発話」の発見に使う (簡易)。

学習の中身:
1. 名前の付いた話者に属する発話の声の特徴 (WeSpeaker の埋め込み) を集める。
   人が指定・確認した発話を重く、自動で割り当てた発話は軽く使い、自動のものは明らかに外れたものを除く。
2. 話者ごとの重心と、話者の違いを強調する変換 (クラス内共分散の白色化 = WCCN, 縮小推定) を求める。
   確認済みの発話を 1 つずつ抜いて当てる試験 (leave-one-out) で、変換で当たり方が悪くなるなら変換は使わない。
3. 話者ごとに「その人らしい」とみなす点数の下限を、本人と他人の点数の分布から決める。

使い方:
- 新しい録音: 話者分離のラベルを、まずこのモデルで名前のある話者に当てる (外れたら従来の照合)
- 学習し直したとき: 人が指定していないラベル・発話を付け直す
- 話者ごとの「確認したい発話」: その人の下限を下回る発話
"""

from __future__ import annotations

import json
import logging
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import numpy as np

from .db import Database, effective_speaker, now_iso

log = logging.getLogger(__name__)

# 1 位と 2 位の点数の差がこれ未満なら、どちらとも決めない
MARGIN = 0.05
# ラベルの話者 (名前あり) から別の人へ、発話 1 つだけを付け替えるのに必要な点数の差
SWITCH_MARGIN = 0.10
# 発話 1 つ単位で付け替えを考える最短の長さ (秒)。短い発話の特徴は当てにならない
REFINE_SECONDS = 1.5
# 名前のない話者で「その人らしくない」とみなす類似度 (学習していないので固定)
PROFILE_SUSPICIOUS = 0.5
# 自動で割り当てた発話のうち、話者の重心からこれより遠いものは学習に使わない
OUTLIER_COS = 0.45
# 学習に使う重み: 人が発話を指定 / 人がラベルを指定 / 自動
WEIGHT_MANUAL, WEIGHT_LABEL, WEIGHT_AUTO = 3.0, 2.0, 1.0
MIN_SPEAKER_WEIGHT = 2.0
# 本人の点数の分布から、これだけ (MAD の倍数) 外れた発話を「その人らしくない」とする
OUTLIER_MADS = 2.5
# 分布から外れたかを見るのに必要な、本人の発話の数
OUTLIER_MIN_SAMPLES = 8
# 確かめた発話がこれだけ集まるまでは、変換を使うかどうかを全部の発話で試験して決める
MIN_CONFIRMED_FOR_EVAL = 20
MODEL_FILE = "speaker_model.npz"
KV_INFO = "speaker_model"


def _normalize_rows(x: np.ndarray) -> np.ndarray:
    n = np.linalg.norm(x, axis=1, keepdims=True)
    return x / np.maximum(n, 1e-9)


@dataclass
class SpeakerModel:
    speaker_ids: list[int]
    centroids: np.ndarray            # 変換後の空間で正規化した重心 (話者数, 次元)
    thresholds: np.ndarray           # 話者ごとの「その人」と認める下限 (話者の割り当てに使う)
    mean: np.ndarray | None = None   # WCCN の中心
    projection: np.ndarray | None = None
    info: dict[str, Any] = field(default_factory=dict)
    # 変換前の空間での重心 (従来の照合に使う話者の平均の声を更新する。保存しない)
    raw_centroids: np.ndarray | None = None
    # 話者ごとの「確認したい発話」の線 (割り当ての下限より厳しい。無ければ割り当ての下限)
    review: np.ndarray | None = None

    def __contains__(self, speaker_id: object) -> bool:
        return speaker_id in self.speaker_ids

    def transform(self, x: np.ndarray) -> np.ndarray:
        x = np.atleast_2d(np.asarray(x, dtype=np.float64))
        if self.projection is not None and self.mean is not None:
            x = (x - self.mean) @ self.projection
        return _normalize_rows(x)

    def score_vector(self, emb: np.ndarray) -> np.ndarray:
        return self.transform(emb)[0] @ self.centroids.T

    def scores(self, emb: np.ndarray) -> dict[int, float]:
        return {sid: float(s) for sid, s in zip(self.speaker_ids, self.score_vector(emb))}

    def threshold(self, speaker_id: int) -> float:
        return float(self.thresholds[self.speaker_ids.index(speaker_id)])

    def review_threshold(self, speaker_id: int) -> float:
        values = self.review if self.review is not None else self.thresholds
        return float(values[self.speaker_ids.index(speaker_id)])

    def best(self, emb: np.ndarray) -> tuple[int | None, float, float]:
        """(最も近い話者, 点数, 2 位との差)"""
        if not self.speaker_ids:
            return None, -1.0, 0.0
        s = self.score_vector(emb)
        order = np.argsort(-s)
        margin = float(s[order[0]] - s[order[1]]) if len(order) > 1 else 1.0
        return self.speaker_ids[int(order[0])], float(s[order[0]]), margin

    def confident(self, emb: np.ndarray) -> tuple[int | None, float]:
        """下限を超え、2 位とも差がある話者がいればその人"""
        best, score, margin = self.best(emb)
        if best is not None and score >= self.threshold(best) and margin >= MARGIN:
            return best, score
        return None, score

    def save(self, path: Path) -> None:
        tmp = path.with_name(path.stem + ".tmp.npz")
        dim = self.centroids.shape[1]
        np.savez(tmp, speaker_ids=np.asarray(self.speaker_ids, dtype=np.int64), centroids=self.centroids,
                 thresholds=self.thresholds,
                 review=self.review if self.review is not None else self.thresholds,
                 mean=self.mean if self.mean is not None else np.zeros(0),
                 projection=self.projection if self.projection is not None else np.zeros((0, dim)),
                 info=np.asarray(json.dumps(self.info, ensure_ascii=False)))
        tmp.replace(path)

    @classmethod
    def load(cls, path: Path) -> SpeakerModel | None:
        try:
            with np.load(path) as z:
                return cls(speaker_ids=[int(i) for i in z["speaker_ids"]], centroids=z["centroids"],
                           thresholds=z["thresholds"], review=z["review"] if "review" in z else None,
                           mean=z["mean"] if z["mean"].size else None,
                           projection=z["projection"] if z["projection"].size else None,
                           info=json.loads(str(z["info"])))
        except (OSError, KeyError, ValueError):
            return None


# --- 学習 -----------------------------------------------------------------

@dataclass
class Sample:
    embedding: np.ndarray
    speaker_id: int
    weight: float
    confirmed: bool


def collect_samples(db: Database) -> list[Sample]:
    """名前の付いた話者に属する、声の特徴のある発話"""
    named = db.named_speakers()
    out: list[Sample] = []
    for u in db.all_utterances(with_embedding=True):
        sid = u["speaker_id"]
        if sid not in named:
            continue
        if u["manual"]:
            out.append(Sample(u["embedding"], sid, WEIGHT_MANUAL, True))
        elif u["label_manual"] and u["auto_speaker_id"] is None:
            out.append(Sample(u["embedding"], sid, WEIGHT_LABEL, True))
        else:
            out.append(Sample(u["embedding"], sid, WEIGHT_AUTO, False))
    return out


def _wccn(x: np.ndarray, y: np.ndarray, w: np.ndarray, shrink: float = 0.5) -> tuple[np.ndarray, np.ndarray]:
    """クラス内共分散を白色化する変換 (縮小推定で、少ない発話でも暴れないようにする)"""
    mu = (w[:, None] * x).sum(0) / w.sum()
    xc = x - mu
    d = x.shape[1]
    sw = np.zeros((d, d))
    for k in np.unique(y):
        m = y == k
        wk = w[m]
        mk = (wk[:, None] * xc[m]).sum(0) / wk.sum()
        diff = xc[m] - mk
        sw += (wk[:, None] * diff).T @ diff
    sw /= w.sum()
    sw = (1 - shrink) * sw + shrink * (np.trace(sw) / d) * np.eye(d)
    evals, evecs = np.linalg.eigh(sw)
    evals = np.maximum(evals, 1e-8)
    return mu, evecs @ np.diag(evals ** -0.5) @ evecs.T


def _centroids(z: np.ndarray, y: np.ndarray, w: np.ndarray, k: int) -> np.ndarray:
    sums = np.zeros((k, z.shape[1]))
    np.add.at(sums, y, w[:, None] * z)
    return _normalize_rows(sums), sums


def _loo_accuracy(z: np.ndarray, y: np.ndarray, w: np.ndarray, k: int, evaluate: np.ndarray) -> tuple[float, int]:
    """1 つずつ抜いて当てる試験の正解率"""
    cents, sums = _centroids(z, y, w, k)
    correct = total = 0
    for i in np.flatnonzero(evaluate):
        own = sums[y[i]] - w[i] * z[i]
        if np.linalg.norm(own) < 1e-9:
            continue  # その話者の発話がこれだけ
        c = cents.copy()
        c[y[i]] = own / np.linalg.norm(own)
        correct += int(np.argmax(c @ z[i]) == y[i])
        total += 1
    return (correct / total if total else 1.0), total


def train(db: Database) -> SpeakerModel | None:
    samples = collect_samples(db)
    by_speaker: dict[int, list[Sample]] = {}
    for s in samples:
        by_speaker.setdefault(s.speaker_id, []).append(s)

    kept: list[Sample] = []
    for ss in by_speaker.values():
        x = _normalize_rows(np.stack([s.embedding for s in ss]))
        w = np.array([s.weight for s in ss])
        c = (w[:, None] * x).sum(0)
        c /= max(np.linalg.norm(c), 1e-9)
        keep = [s for s, xi in zip(ss, x) if s.confirmed or float(xi @ c) >= OUTLIER_COS]
        if sum(s.weight for s in keep) >= MIN_SPEAKER_WEIGHT:
            kept.extend(keep)
    if not kept:
        return None

    ids = sorted({s.speaker_id for s in kept})
    index = {sid: i for i, sid in enumerate(ids)}
    x = _normalize_rows(np.stack([s.embedding for s in kept]).astype(np.float64))
    y = np.array([index[s.speaker_id] for s in kept])
    w = np.array([s.weight for s in kept])
    confirmed = np.array([s.confirmed for s in kept])
    evaluate = confirmed if confirmed.sum() >= MIN_CONFIRMED_FOR_EVAL else np.ones(len(kept), dtype=bool)

    candidates: list[tuple[np.ndarray | None, np.ndarray | None]] = [(None, None)]
    if len(ids) >= 2 and len(kept) >= 10:
        candidates.append(_wccn(x, y, w))
    best: tuple[float, int, np.ndarray | None, np.ndarray | None] | None = None
    for mean, proj in candidates:
        z = _normalize_rows((x - mean) @ proj) if proj is not None else x
        acc, n = _loo_accuracy(z, y, w, len(ids), evaluate)
        if best is None or acc > best[0] + 1e-9:
            best = (acc, n, mean, proj)
    assert best is not None
    accuracy, evaluated, mean, proj = best

    z = _normalize_rows((x - mean) @ proj) if proj is not None else x
    cents, _ = _centroids(z, y, w, len(ids))
    scores = z @ cents.T
    # 「その他」の声 (アナウンス・店員など) も他人の例にして、知らない人を名前のある人と取り違えにくくする
    background = list(getattr(db, "background_embeddings", lambda: [])())
    if background:
        b = _normalize_rows(np.stack(background).astype(np.float64))
        b_scores = (_normalize_rows((b - mean) @ proj) if proj is not None else b) @ cents.T
    else:
        b_scores = np.zeros((0, len(ids)))
    # 点数の幅は変換の有無で変わるので、どちらの線も決まった値では切らない
    thresholds, review = [], []
    for k in range(len(ids)):
        own = scores[y == k, k]
        other = np.concatenate([scores[y != k, k], b_scores[:, k]])
        # 割り当ての下限: 他人との境目 (本人の下位 10% と他人の上位 10% の間)。他人がいなければ本人の下の端
        if len(other):
            accept = min((np.percentile(own, 10) + np.percentile(other, 90)) / 2, np.percentile(own, 25))
        else:
            accept = np.percentile(own, 5) - 0.05
        # 確認したい発話の線: 境目より低いか、本人の点数の分布から外れている (中央値 - 2.5 × MAD より低い)。
        # ただし本人の発話の 4 分の 1 以上は出さないよう、本人の下位 25% の点を上限にする。
        line = accept
        if len(own) >= OUTLIER_MIN_SAMPLES:
            median = float(np.median(own))
            outlier = median - OUTLIER_MADS * 1.4826 * float(np.median(np.abs(own - median)))
            line = min(max(accept, outlier), np.percentile(own, 25))
        thresholds.append(float(accept))
        review.append(float(line))

    names = db.named_speakers()
    info = {
        "trained_at": now_iso(),
        "projection": proj is not None,
        "accuracy": round(accuracy, 3),
        "evaluated": evaluated,
        "samples": len(kept),
        "background": len(background),
        "speakers": [{"id": sid, "name": names.get(sid), "samples": int((y == i).sum()),
                      "confirmed": int(((y == i) & confirmed).sum()), "threshold": round(review[i], 3)}
                     for i, sid in enumerate(ids)],
    }
    raw, _ = _centroids(x, y, w, len(ids))
    return SpeakerModel(ids, cents, np.array(thresholds), mean, proj, info, raw, np.array(review))


# --- 付け直し ---------------------------------------------------------------

def closer_to_current(emb: np.ndarray, current: int | None, learned: int,
                      profiles: dict[int, np.ndarray]) -> bool:
    """今の (名前のない) 話者の平均の声の方が、学習した話者より近いか。

    学習したモデルは名前のある人どうししか区別できないので、名前のない人から付け替えるときはこれで確かめる。
    """
    if current is None or current not in profiles or learned not in profiles:
        return False
    return float(np.dot(emb, profiles[current])) >= float(np.dot(emb, profiles[learned]))


def decide_label(model: SpeakerModel, emb: np.ndarray, current: int | None,
                 profiles: dict[int, np.ndarray]) -> tuple[int | None, float]:
    """ラベルを付け直すべき話者 (変えないなら None)"""
    best, score = model.confident(emb)
    if best is None or best == current:
        return None, score
    if current in model:
        if model.scores(emb)[current] >= model.threshold(current):
            return None, score  # 今の人でも十分その人らしい
    elif closer_to_current(emb, current, best, profiles):
        return None, score
    return best, score


def decide_utterance(model: SpeakerModel, emb: np.ndarray, label_speaker: int | None,
                     profiles: dict[int, np.ndarray]) -> int | None:
    """ラベルの話者と違う人だと言える発話なら、その人"""
    best, score = model.confident(emb)
    if best is None or best == label_speaker:
        return None
    if label_speaker in model:
        own = model.scores(emb)[label_speaker]
        if own >= model.threshold(label_speaker) and score - own < SWITCH_MARGIN:
            return None
    elif closer_to_current(emb, label_speaker, best, profiles):
        return None
    return best


def speaker_score(model: SpeakerModel | None, profiles: dict[int, np.ndarray], speaker_id: int | None,
                  emb: np.ndarray) -> float | None:
    """発話がその話者らしい度合い。学習した話者はモデルの点数、それ以外は話者の平均の声との類似度。"""
    if speaker_id is None:
        return None
    if model is not None and speaker_id in model:
        return model.scores(emb)[speaker_id]
    if speaker_id in profiles:
        return float(np.dot(emb, profiles[speaker_id]))
    return None


def suspicious_below(model: SpeakerModel | None, speaker_id: int) -> float:
    if model is not None and speaker_id in model:
        return model.review_threshold(speaker_id)
    return PROFILE_SUSPICIOUS


def apply_model(db: Database, model: SpeakerModel | None, segment_ids: set[str] | None = None) -> dict[str, Any]:
    """人が指定していないラベル・発話を付け直し、発話ごとの「らしさ」を書き直す。"""
    changed: set[str] = set()
    labels_changed = 0
    profiles = {sid: vec for sid, vec, _ in db.speaker_profiles()}
    if model is not None:
        for row in db.label_rows():
            if row["manual"] or (segment_ids is not None and row["segment_id"] not in segment_ids):
                continue
            new, score = decide_label(model, row["embedding"], row["speaker_id"], profiles)
            if new is not None:
                db.set_label_speaker(row["segment_id"], row["label"], new, score)
                labels_changed += 1
                changed.add(row["segment_id"])

    updates: list[tuple[int, int | None, float | None]] = []
    utterances_changed = 0
    for u in db.all_utterances(with_embedding=True):
        if segment_ids is not None and u["segment_id"] not in segment_ids:
            continue
        auto = u["auto_speaker_id"]
        if not u["manual"]:
            auto = None
            if model is not None and u["end_s"] - u["start_s"] >= REFINE_SECONDS:
                auto = decide_utterance(model, u["embedding"], u["label_speaker_id"], profiles)
        effective = effective_speaker({**u, "auto_speaker_id": auto})
        score = speaker_score(model, profiles, effective, u["embedding"])
        score = None if score is None else round(score, 4)
        if auto != u["auto_speaker_id"]:
            utterances_changed += 1
            changed.add(u["segment_id"])
        if auto != u["auto_speaker_id"] or score != (None if u["score"] is None else round(u["score"], 4)):
            updates.append((u["id"], auto, score))
    db.update_utterance_scores(updates)
    return {"labels_changed": labels_changed, "utterances_changed": utterances_changed, "segments": sorted(changed)}


def model_path(data_dir: Path) -> Path:
    return data_dir / MODEL_FILE


def retrain(db: Database, data_dir: Path) -> tuple[SpeakerModel | None, dict[str, Any]]:
    """学習し直して、過去の記録にも当てはめる。"""
    model = train(db)
    path = model_path(data_dir)
    if model is not None:
        model.save(path)
        # 従来の照合 (学習していない話者との比較) でも、学習に使った発話の重心を話者の平均の声にする
        weights = {sid: w for sid, _v, w in db.speaker_profiles()}
        if model.raw_centroids is not None:
            for sid, centroid in zip(model.speaker_ids, model.raw_centroids):
                db.update_speaker_embedding(sid, centroid, weights.get(sid, 1.0))
    else:
        path.unlink(missing_ok=True)
    report = apply_model(db, model)
    info = dict(model.info) if model is not None else {"trained_at": now_iso(), "samples": 0, "speakers": []}
    info.update(labels_changed=report["labels_changed"], utterances_changed=report["utterances_changed"])
    db.set_kv(KV_INFO, json.dumps(info, ensure_ascii=False))
    log.info("speaker model: %s", {k: v for k, v in info.items() if k != "speakers"})
    return model, report


def model_info(db: Database) -> dict[str, Any] | None:
    raw = db.get_kv(KV_INFO)
    return json.loads(raw) if raw else None


# --- iPhone へ渡す学習済みの声 -------------------------------------------------

def _b64(x: np.ndarray) -> str:
    import base64
    return base64.b64encode(np.ascontiguousarray(x, dtype="<f4").tobytes()).decode("ascii")


def voices_payload(db: Database, model: SpeakerModel | None, *, diarization_threshold: float,
                   match_threshold: float, min_seconds: float, embedding_model: str) -> dict[str, Any]:
    """iPhone が自分で話者分離した結果に名前を当てるための、声のプロファイルと学習済みモデル。

    同じ埋め込みモデル (WeSpeaker) を Core ML に変換したものを iPhone で使うので、ベクトルはそのまま比べられる。
    version は中身のハッシュ (変わっていなければ iPhone は取り直さない)。
    """
    import hashlib

    names = {s["id"]: s for s in db.list_speakers()}
    profiles = []
    for sid, vec, weight in db.speaker_profiles():
        s = names.get(sid, {})
        profiles.append({"id": sid, "name": s.get("name"), "ignored": bool(s.get("ignored")),
                         "weight": round(float(weight), 3), "vector": _b64(vec)})
    payload: dict[str, Any] = {
        "source": "server",
        "embedding_model": embedding_model,
        "settings": {"diarization_threshold": diarization_threshold, "match_threshold": match_threshold,
                     "min_seconds": min_seconds},
        "profiles": profiles,
        "model": None,
    }
    if model is not None:
        payload["model"] = {
            "speaker_ids": list(model.speaker_ids),
            "centroids": [_b64(c) for c in model.centroids],
            "thresholds": [float(t) for t in model.thresholds],
            "review": [float(t) for t in (model.review if model.review is not None else model.thresholds)],
            "mean": None if model.mean is None else _b64(model.mean),
            "projection": None if model.projection is None else _b64(model.projection),
        }
    digest = hashlib.sha256(json.dumps(payload, sort_keys=True).encode()).hexdigest()[:16]
    return {"version": digest, **payload}
