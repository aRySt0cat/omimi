import sqlite3

import numpy as np
import pytest

from omi_home_server import models
from omi_home_server.db import Database
from omi_home_server.diarize import label_for
from omi_home_server.stt import Piece, regions_from_turns, transcribe_regions


def test_regions_merge_same_speaker_and_split_long():
    turns = [{"start": 0, "end": 2, "label": "S0"}, {"start": 2.5, "end": 4, "label": "S0"},
             {"start": 4.2, "end": 6, "label": "S1"}, {"start": 10, "end": 70, "label": "S0"}]
    regions = regions_from_turns(turns, pad=0, duration=80)
    assert regions[0] == (0, 4, "S0")
    assert regions[1] == (4.2, 6, "S1")
    assert [r[2] for r in regions[2:]] == ["S0", "S0", "S0"]
    assert all(e - s <= 28 for s, e, _ in regions)
    assert regions[-1][1] == 70


def test_label_for_overlap_and_nearest():
    turns = [{"start": 0, "end": 2, "label": "S0"}, {"start": 2, "end": 5, "label": "S1"}]
    assert label_for(1.5, 3.5, turns) == "S1"
    assert label_for(5.3, 5.6, turns) == "S1"   # 重なりなしでも近ければ
    assert label_for(20, 21, turns) is None


class LangEngine:
    name, model = "lang", ""

    def __init__(self):
        self.detected = []

    def detect_language(self, audio, candidates):
        lang = "en" if audio.mean() > 0 else "ja"
        self.detected.append(lang)
        return lang, 0.9

    def transcribe(self, audio, language=None, hotwords=None):
        return [Piece(0, len(audio) / 16000, f"text-{language}", language)]


def test_language_detected_per_region():
    audio = np.concatenate([-np.ones(16000 * 2), np.ones(16000 * 2)]).astype(np.float32) * 0.1
    turns = [{"start": 0, "end": 2, "label": "S0"}, {"start": 2, "end": 4, "label": "S1"}]
    pieces = transcribe_regions(LangEngine(), audio, turns, ["ja", "en"])
    assert [(p.language, p.speaker_label, p.text) for p in pieces] == [("ja", "S0", "text-ja"), ("en", "S1", "text-en")]


def test_short_region_inherits_previous_language():
    eng = LangEngine()
    audio = np.ones(16000 * 4, dtype=np.float32) * 0.1
    turns = [{"start": 0, "end": 2, "label": "S0"}, {"start": 3, "end": 3.4, "label": "S1"}]
    pieces = transcribe_regions(eng, audio, turns, ["ja", "en"])
    assert eng.detected == ["en"]  # 前後の余白込みで 1 秒未満の区間は判別しない
    assert [p.language for p in pieces] == ["en", "en"]


def test_single_language_skips_detection():
    eng = LangEngine()
    audio = np.ones(16000 * 2, dtype=np.float32)
    pieces = transcribe_regions(eng, audio, [{"start": 0, "end": 2, "label": "S0"}], ["ja"])
    assert eng.detected == [] and pieces[0].language == "ja"


def test_migrates_old_database(tmp_path):
    path = tmp_path / "old.sqlite3"
    c = sqlite3.connect(path)
    c.execute("""CREATE TABLE segments (id TEXT PRIMARY KEY, started_at TEXT NOT NULL, received_at TEXT NOT NULL,
                 server_stt_status TEXT NOT NULL DEFAULT 'none', server_stt_error TEXT, audio_path TEXT,
                 audio_sha256 TEXT, audio_bytes INTEGER, source TEXT, device_id TEXT, device_name TEXT, firmware TEXT,
                 codec TEXT, sample_rate INTEGER, ended_at TEXT, duration_seconds REAL, frame_count INTEGER,
                 concealed_frames INTEGER)""")
    c.execute("INSERT INTO segments (id, started_at, received_at) VALUES ('a', '2026-01-01T00:00:00Z', 'x')")
    c.commit()
    c.close()
    db = Database(path)
    assert db.get_segment("a")["diarization_status"] == "none"


def test_speaker_merge_combines_embeddings(tmp_path):
    db = Database(tmp_path / "x.sqlite3")
    a = db.create_speaker(np.array([1, 0], dtype=np.float32), 10)
    b = db.create_speaker(np.array([0, 1], dtype=np.float32), 10, name="田中")
    assert db.merge_speakers(a, b)
    profiles = db.speaker_profiles()
    assert [p[0] for p in profiles] == [b]
    assert np.allclose(profiles[0][1], np.array([1, 1]) / np.sqrt(2), atol=1e-6)
    assert db.list_speakers()[0]["display_name"] == "田中"


def test_model_missing_without_download(tmp_path):
    with pytest.raises(models.ModelUnavailable):
        models.ensure(models.EMBEDDING, tmp_path, allow_download=False)
    (tmp_path / models.EMBEDDING.dest).write_bytes(b"x")
    path = models.ensure(models.EMBEDDING, tmp_path, allow_download=False)
    assert path.exists()
    assert not models.verify(models.EMBEDDING, path)  # 中身が違うものは検出する


def test_has_speech_ignores_tiny_turns():
    from omi_home_server.exporter import has_speech

    seg = {"diarization_status": "done", "turns_json": '[{"start": 0, "end": 0.7, "label": "S0"}]'}
    assert has_speech(seg, []) is False
    seg["turns_json"] = '[{"start": 0, "end": 0.7, "label": "S0"}, {"start": 3, "end": 3.5, "label": "S0"}]'
    assert has_speech(seg, []) is True
    assert has_speech({"diarization_status": "queued"}, []) is None
    assert has_speech({"diarization_status": "queued"}, [{"pieces": [{"text": "x"}]}]) is True


def test_worker_loop_survives_unexpected_errors(tmp_path):
    """処理中の思わぬ失敗でスレッドが止まらない (止まると録音が静かにたまっていく)"""
    import threading

    from omi_home_server.config import Settings
    from omi_home_server.db import Database
    from omi_home_server.worker import TranscriptionWorker

    settings = Settings(data_dir=tmp_path, stt_engine="none")
    worker = TranscriptionWorker(Database(tmp_path / "omi.sqlite3"), settings)
    calls = []

    def flaky():
        calls.append(1)
        if len(calls) == 1:
            raise RuntimeError("database is locked")
        if len(calls) >= 3:
            worker._stop.set()

    worker._stop.wait = lambda timeout=None: False  # 待たない
    worker._diar_round = flaky
    worker._diar_wake.wait = lambda timeout=None: True
    t = threading.Thread(target=worker._diar_loop)
    t.start()
    t.join(5)
    assert not t.is_alive() and len(calls) >= 3
    assert "database is locked" in worker.last_error
