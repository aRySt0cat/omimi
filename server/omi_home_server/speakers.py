"""話者識別: セグメント内の話者を、録音をまたいだ話者プロファイルに対応付ける。"""

from __future__ import annotations

import logging
from typing import TYPE_CHECKING, Any

import numpy as np

from .db import Database

if TYPE_CHECKING:
    from .speaker_model import SpeakerModel

log = logging.getLogger(__name__)


def identify(db: Database, seg_id: str, embeddings: dict[str, tuple[np.ndarray, float]], *,
             match_threshold: float, min_seconds: float, model: SpeakerModel | None = None) -> dict[str, dict[str, Any]]:
    """各話者ラベルを既知の話者に照合する。

    - 名前を付けた話者を学習したモデルがあれば、まずそれで当てる (その人の下限を超え、2 位とも差があるとき)
    - 当たらなければ、学習していない話者の中から、類似度が `match_threshold` 以上の人とし、平均ベクトルを更新する
    - いなければ、発話が `min_seconds` 以上なら新しい話者 (「話者<id>」) として登録する
    - それ未満は「不明」(speaker_id なし)

    戻り値: {label: {speaker_id, similarity, seconds}}
    """
    all_profiles = {sid: (vec, w) for sid, vec, w in db.speaker_profiles()}
    # 学習した話者はモデルの判断に任せる
    profiles = {sid: pw for sid, pw in all_profiles.items() if model is None or sid not in model}
    rows: list[dict[str, Any]] = []
    result: dict[str, dict[str, Any]] = {}
    # 発話の長い話者から割り当てる (推定が安定しているため)
    for label, (emb, seconds) in sorted(embeddings.items(), key=lambda kv: -kv[1][1]):
        best_id, best_sim = None, -1.0
        for sid, (vec, _w) in profiles.items():
            sim = float(np.dot(emb, vec))
            if sim > best_sim:
                best_id, best_sim = sid, sim
        if model is not None:
            learned, score = model.confident(emb)
            learned_sim = float(np.dot(emb, all_profiles[learned][0])) if learned in all_profiles else 1.0
            # 名前のない既知の話者の方が近ければ、そちらにする (モデルは名前のある人どうししか区別できない)
            if learned is not None and not (best_id is not None and best_sim >= match_threshold and best_sim > learned_sim):
                rows.append({"label": label, "speaker_id": learned, "seconds": seconds, "similarity": score, "embedding": emb})
                result[label] = {"speaker_id": learned, "similarity": score, "seconds": seconds}
                log.info("segment %s %s -> speaker %s (model score=%.3f, %.1fs)", seg_id, label, learned, score, seconds)
                continue
        speaker_id: int | None = None
        similarity: float | None = None
        if best_id is not None and best_sim >= match_threshold:
            speaker_id, similarity = best_id, best_sim
            vec, w = profiles[best_id]
            updated = vec * w + emb * seconds
            db.update_speaker_embedding(best_id, updated, w + seconds)
            profiles[best_id] = (updated / max(np.linalg.norm(updated), 1e-9), w + seconds)
        elif seconds >= min_seconds:
            speaker_id = db.create_speaker(emb, seconds)
            profiles[speaker_id] = (emb, seconds)
        rows.append({"label": label, "speaker_id": speaker_id, "seconds": seconds,
                     "similarity": similarity, "embedding": emb})
        result[label] = {"speaker_id": speaker_id, "similarity": similarity, "seconds": seconds}
        log.info("segment %s %s -> speaker %s (sim=%s, %.1fs)", seg_id, label, speaker_id,
                 None if similarity is None else round(similarity, 3), seconds)
    db.replace_segment_speakers(seg_id, rows)
    return result
