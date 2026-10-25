import base64
import hashlib
import json
from pathlib import Path

import numpy as np
import pytest
from fastapi.testclient import TestClient

from omi_home_server.app import create_app
from omi_home_server.audio import load_audio, speech_regions
from omi_home_server.cli import cert_fingerprint
from omi_home_server.config import Settings
from omi_home_server.diarize import Turn
from omi_home_server.stt import Piece

TOKEN = "test-token"


def make_ogg(path: Path, seconds: float = 2.0) -> bytes:
    """PyAV (同梱 FFmpeg の libopus) で 16 kHz の Ogg Opus を作る。"""
    import av

    t = np.arange(int(16000 * seconds)) / 16000
    pcm = (0.3 * np.sin(2 * np.pi * 440 * t) * 32767).astype(np.int16)
    with av.open(str(path), "w", format="ogg") as out:
        stream = out.add_stream("libopus", rate=16000)
        stream.layout = "mono"
        frame = av.AudioFrame.from_ndarray(pcm.reshape(1, -1), format="s16", layout="mono")
        frame.sample_rate = 16000
        for packet in stream.encode(frame):
            out.mux(packet)
        for packet in stream.encode(None):
            out.mux(packet)
    return path.read_bytes()


class FakeEngine:
    name = "fake"
    model = "m1"

    def __init__(self, settings):
        self.calls = 0

    def transcribe(self, audio, language=None, hotwords=None):
        self.calls += 1
        assert audio.dtype == np.float32
        text = "hello" if language == "en" else "こんにちは"
        return [Piece(0.0, len(audio) / 16000, text, language)]

    def detect_language(self, audio, candidates):
        return "ja", 0.9


A = np.array([1.0, 0.0, 0.0], dtype=np.float32)
B = np.array([0.0, 1.0, 0.0], dtype=np.float32)


class FakeDiarizer:
    """0〜1 秒は話者 A、1〜2 秒は話者 B"""

    def __init__(self, settings):
        pass

    def diarize(self, audio):
        return [Turn(0.0, 1.0, "S0"), Turn(1.0, 2.0, "S1")]

    def speaker_embeddings(self, audio, turns):
        return {"S0": (A, 4.0), "S1": (B, 4.0)}


def metadata_header(seg_id: str, **extra) -> str:
    meta = {"id": seg_id, "started_at": "2026-10-10T03:00:00.000Z", "duration_seconds": 2.0,
            "codec": "opus_fs320", "sample_rate": 16000, **extra}
    return base64.urlsafe_b64encode(json.dumps(meta).encode()).decode().rstrip("=")


@pytest.fixture
def env(tmp_path):
    settings = Settings(data_dir=tmp_path / "data", api_tokens=[TOKEN], stt_engine="fake-for-test")
    app = create_app(settings, engine_factory=FakeEngine, diarizer_factory=FakeDiarizer, start_worker=False)
    client = TestClient(app)
    client.headers["Authorization"] = f"Bearer {TOKEN}"
    ogg = make_ogg(tmp_path / "a.opus")
    return client, app, ogg, settings


def put_audio(client, seg_id, ogg, transcribe="0", **extra):
    return client.put(f"/api/v1/segments/{seg_id}/audio", content=ogg, headers={
        "Content-Type": "audio/ogg", "X-Omi-Metadata": metadata_header(seg_id, **extra),
        "X-Content-SHA256": hashlib.sha256(ogg).hexdigest(), "X-Omi-Transcribe": transcribe})


def test_auth_required(env):
    client, *_ = env
    assert client.get("/api/v1/health", headers={"Authorization": "Bearer nope"}).status_code == 401
    assert client.get("/api/v1/health", headers={"Authorization": ""}).status_code == 401
    assert client.get("/api/v1/health").json()["status"] == "ok"


def test_upload_and_device_transcript(env):
    client, app, ogg, settings = env
    seg = "20261010T030000Z-abcd1234"
    r = put_audio(client, seg, ogg)
    assert r.status_code == 200, r.text
    assert r.json()["server_transcription"] == "none"
    stored = settings.data_dir / "audio/2026/10/10" / f"{seg}.opus"
    assert stored.read_bytes() == ogg

    r = client.put(f"/api/v1/segments/{seg}/device-transcript", json={
        "engine": "apple-speech", "locale": "ja-JP", "created_at": "2026-10-10T03:06:00.000Z",
        "pieces": [{"start": 0.1, "end": 1.2, "text": "明日の会議"}]})
    assert r.status_code == 200, r.text

    detail = client.get(f"/api/v1/segments/{seg}").json()
    assert detail["duration_seconds"] == 2.0
    assert detail["transcripts"][0]["origin"] == "device"
    assert detail["transcripts"][0]["pieces"][0]["text"] == "明日の会議"

    listed = client.get("/api/v1/segments", params={"start": "2026-10-10T00:00:00Z", "end": "2026-10-11T00:00:00Z"})
    assert [s["id"] for s in listed.json()["segments"]] == [seg]

    found = client.get("/api/v1/search", params={"q": "会議"}).json()["results"]
    assert found[0]["segment_id"] == seg
    assert client.get("/api/v1/search", params={"q": "存在しない"}).json()["results"] == []

    assert client.get(f"/api/v1/segments/{seg}/audio").content == ogg
    sidecar = json.loads(stored.with_suffix(".json").read_text())
    assert sidecar["transcripts"][0]["text"] == "明日の会議"


def test_server_transcription_when_requested(env):
    client, app, ogg, _ = env
    seg = "20261010T030500Z-00000001"
    assert put_audio(client, seg, ogg, transcribe="1").json()["server_transcription"] == "queued"
    # 話者分離が終わるまで文字起こしは始めない
    assert app.state.db.next_transcription_job(wait_for_diarization=True) is None
    assert app.state.worker.drain() == 2  # 話者分離 + 文字起こし
    detail = client.get(f"/api/v1/segments/{seg}").json()
    assert detail["server_stt_status"] == "done"
    server = [t for t in detail["transcripts"] if t["origin"] == "server"][0]
    assert server["engine"] == "fake:m1"
    # 話者分離の区間ごとに文字起こしされ、話者が付く
    assert [p["speaker_label"] for p in server["pieces"]] == ["S0", "S1"]
    # 名前のない声は「その他」と表示する (声は ID で区別したまま)
    assert [p["speaker"] for p in server["pieces"]] == ["その他", "その他"]
    assert len({p["speaker_id"] for p in server["pieces"]}) == 2
    assert all(p["language"] == "ja" for p in server["pieces"])
    # 同じ音声の再送では再度キューに積まない
    assert put_audio(client, seg, ogg, transcribe="1").json()["server_transcription"] == "done"
    assert app.state.worker.drain() == 0


def test_manual_transcription_request(env):
    client, app, ogg, _ = env
    seg = "20261010T031000Z-00000002"
    put_audio(client, seg, ogg)
    assert app.state.worker.drain() == 1  # 話者分離
    assert client.post(f"/api/v1/segments/{seg}/transcribe").json()["server_transcription"] == "queued"
    assert app.state.worker.drain() == 1


def device_transcript(client, seg):
    return client.put(f"/api/v1/segments/{seg}/device-transcript", json={
        "engine": "apple-speech", "locale": "ja-JP+en-US",
        "pieces": [{"start": 0.1, "end": 0.9, "text": "おはよう", "language": "ja"},
                   {"start": 1.1, "end": 1.9, "text": "Good morning", "language": "en"}]})


def pieces_of(client, seg, origin="device"):
    detail = client.get(f"/api/v1/segments/{seg}").json()
    return [t for t in detail["transcripts"] if t["origin"] == origin][0]["pieces"]


def test_speakers_identified_across_segments(env):
    client, app, ogg, _ = env
    s1, s2 = "20261010T040000Z-00000001", "20261010T050000Z-00000002"
    assert put_audio(client, s1, ogg).json()["diarization"] == "queued"
    device_transcript(client, s1)
    put_audio(client, s2, ogg)
    device_transcript(client, s2)
    assert app.state.worker.drain() == 2

    # 端末の文字起こしにも時刻の重なりで話者が付く。言語はそのまま残る。
    p1 = pieces_of(client, s1)
    assert [(p["speaker"], p["language"]) for p in p1] == [("その他", "ja"), ("その他", "en")]
    assert p1[0]["speaker_id"] != p1[1]["speaker_id"]
    # 別の録音でも同じ声は同じ話者
    assert [p["speaker_id"] for p in pieces_of(client, s2)] == [p["speaker_id"] for p in p1]

    speakers = client.get("/api/v1/speakers").json()["speakers"]
    assert len(speakers) == 2 and all(sp["segments"] == 2 for sp in speakers)

    # 名前を付けると過去の記録にも反映される
    me = p1[0]["speaker_id"]
    assert client.patch(f"/api/v1/speakers/{me}", json={"name": "自分"}).status_code == 200
    assert pieces_of(client, s2)[0]["speaker"] == "自分"

    # 同一人物だった場合はまとめる
    other = p1[1]["speaker_id"]
    assert client.post(f"/api/v1/speakers/{other}/merge", json={"into": me}).status_code == 200
    assert [p["speaker"] for p in pieces_of(client, s1)] == ["自分", "自分"]
    assert len(client.get("/api/v1/speakers").json()["speakers"]) == 1
    assert client.post(f"/api/v1/speakers/{me}/merge", json={"into": me}).status_code == 404


def test_assign_speaker_by_name(env):
    client, app, ogg, _ = env
    seg = "20261010T060000Z-00000003"
    put_audio(client, seg, ogg)
    device_transcript(client, seg)
    app.state.worker.drain()
    r = client.put(f"/api/v1/segments/{seg}/speakers/S1", json={"name": "田中さん"})
    assert r.status_code == 200, r.text
    assert pieces_of(client, seg)[1]["speaker"] == "田中さん"
    # 同じ名前を指定すると既存の話者に付け替える
    r2 = client.put(f"/api/v1/segments/{seg}/speakers/S0", json={"name": "田中さん"})
    assert r2.json()["speaker_id"] == r.json()["speaker_id"]
    assert client.put(f"/api/v1/segments/{seg}/speakers/S9", json={"name": "x"}).status_code == 404
    assert client.put(f"/api/v1/segments/{seg}/speakers/S0", json={}).status_code == 400


def test_assign_short_label_without_embedding(tmp_path):
    class WithShortTurn(FakeDiarizer):
        def diarize(self, audio):
            return [Turn(0.0, 1.0, "S0"), Turn(1.0, 1.3, "S5")]  # S5 は短くて埋め込みなし

        def speaker_embeddings(self, audio, turns):
            return {"S0": (A, 4.0)}

    settings = Settings(data_dir=tmp_path / "d", api_tokens=[TOKEN], stt_engine="none")
    app = create_app(settings, diarizer_factory=WithShortTurn, start_worker=False)
    client = TestClient(app)
    client.headers["Authorization"] = f"Bearer {TOKEN}"
    put_audio(client, "s1", make_ogg(tmp_path / "b.opus"))
    app.state.worker.drain()
    client.patch("/api/v1/speakers/1", json={"name": "自分"})
    # 新しい名前は登録できない (声の特徴がない) が、既存の話者には付け替えられる
    assert client.put("/api/v1/segments/s1/speakers/S5", json={"name": "新しい人"}).status_code == 409
    assert client.put("/api/v1/segments/s1/speakers/S5", json={"name": "自分"}).status_code == 200
    assert client.get("/api/v1/segments/s1").json()["speakers"]["S5"]["speaker"] == "自分"


def test_short_speaker_stays_unknown(tmp_path):
    class Short(FakeDiarizer):
        def speaker_embeddings(self, audio, turns):
            return {"S0": (A, 1.0)}  # 3 秒未満

    settings = Settings(data_dir=tmp_path / "d", api_tokens=[TOKEN], stt_engine="none")
    app = create_app(settings, diarizer_factory=Short, start_worker=False)
    client = TestClient(app)
    client.headers["Authorization"] = f"Bearer {TOKEN}"
    ogg = make_ogg(tmp_path / "b.opus")
    put_audio(client, "s1", ogg)
    app.state.worker.drain()
    assert client.get("/api/v1/speakers").json()["speakers"] == []
    assert client.get("/api/v1/segments/s1").json()["speakers"]["S0"]["speaker_id"] is None


def test_diarization_disabled(tmp_path):
    settings = Settings(data_dir=tmp_path / "d", api_tokens=[TOKEN], stt_engine="none", diarization=False)
    app = create_app(settings, start_worker=False)
    client = TestClient(app)
    client.headers["Authorization"] = f"Bearer {TOKEN}"
    ogg = make_ogg(tmp_path / "b.opus")
    assert put_audio(client, "s1", ogg).json()["diarization"] == "none"
    assert client.post("/api/v1/segments/s1/diarize").status_code == 409


def test_rejects_bad_input(env):
    client, _, ogg, _ = env
    assert client.put("/api/v1/segments/../../etc/audio", content=ogg).status_code in (400, 404)
    assert client.put("/api/v1/segments/a.b/audio", content=ogg,
                      headers={"X-Omi-Metadata": metadata_header("a.b")}).status_code == 400
    r = client.put("/api/v1/segments/x1/audio", content=ogg,
                   headers={"X-Omi-Metadata": metadata_header("x1"), "X-Content-SHA256": "00" * 32})
    assert r.status_code == 400 and "sha256" in r.text
    r = client.put("/api/v1/segments/x2/audio", content=b"not ogg", headers={"X-Omi-Metadata": metadata_header("x2")})
    assert r.status_code == 400
    assert client.put("/api/v1/segments/x3/audio", content=ogg).status_code == 400  # metadata 無し
    r = client.put("/api/v1/segments/x4/device-transcript", json={"engine": "e", "pieces": []})
    assert r.status_code == 409


def test_policy_always(tmp_path):
    settings = Settings(data_dir=tmp_path / "d", api_tokens=[TOKEN], stt_engine="x", transcribe_policy="always")
    client = TestClient(create_app(settings, engine_factory=FakeEngine, diarizer_factory=FakeDiarizer,
                                   start_worker=False))
    client.headers["Authorization"] = f"Bearer {TOKEN}"
    ogg = make_ogg(tmp_path / "b.opus")
    assert put_audio(client, "s1", ogg, transcribe="0").json()["server_transcription"] == "queued"


def test_policy_never_and_engine_none(tmp_path):
    settings = Settings(data_dir=tmp_path / "d", api_tokens=[TOKEN], stt_engine="none", diarization=False)
    client = TestClient(create_app(settings, start_worker=False))
    client.headers["Authorization"] = f"Bearer {TOKEN}"
    ogg = make_ogg(tmp_path / "b.opus")
    assert put_audio(client, "s1", ogg, transcribe="1").json()["server_transcription"] == "none"


def test_generated_token(tmp_path):
    settings = Settings(data_dir=tmp_path / "d")
    token = settings.resolve_tokens()[0]
    assert len(token) >= 32
    assert (tmp_path / "d" / "token").stat().st_mode & 0o777 == 0o600
    assert Settings(data_dir=tmp_path / "d").resolve_tokens()[0] == token


def test_audio_decode_and_vad(tmp_path):
    ogg = tmp_path / "a.opus"
    make_ogg(ogg, seconds=1.0)
    audio = load_audio(ogg)
    assert audio.dtype == np.float32 and abs(len(audio) - 16000) < 1000

    silence = np.zeros(16000 * 5, dtype=np.float32) + np.random.default_rng(0).normal(0, 1e-4, 16000 * 5).astype(np.float32)
    tone = 0.2 * np.sin(2 * np.pi * 300 * np.arange(16000 * 2) / 16000).astype(np.float32)
    mixed = np.concatenate([silence, tone, silence])
    regions = speech_regions(mixed)
    assert len(regions) == 1
    s, e = regions[0]
    assert abs(s / 16000 - 5.0) < 0.5 and abs(e / 16000 - 7.0) < 0.5
    assert speech_regions(silence) == [] or all((e - s) < 16000 for s, e in speech_regions(silence))


def test_cert_fingerprint(tmp_path):
    der = b"\x30\x03\x02\x01\x01"
    pem = tmp_path / "c.pem"
    pem.write_text("-----BEGIN CERTIFICATE-----\n" + base64.b64encode(der).decode() + "\n-----END CERTIFICATE-----\n")
    fp = cert_fingerprint(pem)
    assert fp.replace(":", "").lower() == hashlib.sha256(der).hexdigest()


def test_markers_and_timeline_export(tmp_path):
    settings = Settings(data_dir=tmp_path / "d", api_tokens=[TOKEN], stt_engine="fake", timezone="Asia/Tokyo")
    app = create_app(settings, engine_factory=FakeEngine, diarizer_factory=FakeDiarizer, start_worker=False)
    client = TestClient(app)
    client.headers["Authorization"] = f"Bearer {TOKEN}"
    ogg = make_ogg(tmp_path / "a.opus")
    seg = "20261010T030000Z-00000001"  # 2026-10-10 12:00:00 JST
    put_audio(client, seg, ogg, transcribe="1")
    device_transcript(client, seg)
    # 録音中の注目 / 録音の外のメモ / 区切り
    assert client.put("/api/v1/markers/m1", json={"kind": "highlight", "at": "2026-10-10T03:00:00.500Z"}).status_code == 200
    assert client.put("/api/v1/markers/m2", json={"kind": "memo", "at": "2026-10-10T03:30:00Z", "device_id": "d"}).status_code == 200
    assert client.put("/api/v1/markers/m3", json={"kind": "split", "at": "2026-10-10T03:00:01.900Z"}).status_code == 200
    assert client.put("/api/v1/markers/bad", json={"kind": "nope", "at": "2026-10-10T03:00:00Z"}).status_code == 400
    client.patch("/api/v1/speakers/1", json={"name": "自分"})  # 話者はまだ無いので 404 だが害はない
    app.state.worker.drain()
    client.patch("/api/v1/speakers/1", json={"name": "自分"})
    app.state.worker.flush_exports()

    markers = client.get("/api/v1/markers", params={"start": "2026-10-10T00:00:00Z"}).json()["markers"]
    assert [m["kind"] for m in markers] == ["highlight", "split", "memo"]

    data = settings.data_dir
    assert (data / "AGENTS.md").read_text().startswith("# このディレクトリについて")
    md = (data / "timeline" / "2026-10-10.md").read_text()
    assert "# 2026-10-10 (土) のライフログ" in md
    assert "## 12:00:00 – 12:00:02" in md
    assert "**自分** (ja): こんにちは" in md
    assert "⭐ **注目**" in md and "📝 **メモ**" in md and "✂️ **区切り**" in md
    assert "+0900" in md
    records = [json.loads(line) for line in (data / "timeline" / "2026-10-10.jsonl").read_text().splitlines()]
    types = [r["type"] for r in records]
    assert types[0] == "segment" and records[0]["has_speech"] is True and records[0]["transcript_source"] == "server"
    assert records[0]["start"].startswith("2026-10-10T12:00:00")
    marker_recs = {r["id"]: r for r in records if r["type"] == "marker"}
    assert marker_recs["m1"]["segment_id"] == seg       # 録音の時間内
    assert marker_recs["m2"]["segment_id"] is None      # 録音の外
    utt = [r for r in records if r["type"] == "utterance"]
    assert {u["speaker"] for u in utt} == {"自分", "その他"} and all(u["source"] == "server" for u in utt)

    # 印の削除・セグメントの削除で書き出しも更新される
    assert client.delete("/api/v1/markers/m2").status_code == 200
    assert client.delete(f"/api/v1/segments/{seg}").json() == {"deleted": [seg]}
    app.state.worker.flush_exports()
    assert not (data / "audio/2026/10/10" / f"{seg}.opus").exists()
    remaining = [json.loads(line)["type"] for line in (data / "timeline" / "2026-10-10.jsonl").read_text().splitlines()]
    assert remaining == ["marker", "marker"]
    assert client.get(f"/api/v1/segments/{seg}").status_code == 404


def test_silent_segments_and_bulk_delete(tmp_path):
    class Silent(FakeDiarizer):
        def diarize(self, audio):
            return []

        def speaker_embeddings(self, audio, turns):
            return {}

    settings = Settings(data_dir=tmp_path / "d", api_tokens=[TOKEN], stt_engine="none")
    app = create_app(settings, diarizer_factory=Silent, start_worker=False)
    client = TestClient(app)
    client.headers["Authorization"] = f"Bearer {TOKEN}"
    ogg = make_ogg(tmp_path / "a.opus")
    for i in range(3):
        put_audio(client, f"s{i}", ogg)
    assert client.get("/api/v1/segments/s0").json()["has_speech"] is None  # 未処理
    app.state.worker.drain()
    segs = client.get("/api/v1/segments").json()["segments"]
    assert [s["has_speech"] for s in segs] == [False, False, False]
    md = (settings.data_dir / "timeline" / "2026-10-10.md").read_text()
    assert "話し声なし 3 件" in md and "## " not in md
    r = client.post("/api/v1/segments/delete", json={"ids": ["s0", "s1", "nope", "../x"]})
    assert r.json()["deleted"] == ["s0", "s1"]
    assert [s["id"] for s in client.get("/api/v1/segments").json()["segments"]] == ["s2"]


def test_transcription_skipped_without_speech(tmp_path):
    class Silent(FakeDiarizer):
        def diarize(self, audio):
            return []

        def speaker_embeddings(self, audio, turns):
            return {}

    class Boom(FakeEngine):
        def transcribe(self, audio, language=None, hotwords=None):
            raise AssertionError("話し声のない録音は Whisper に掛けない")

    settings = Settings(data_dir=tmp_path / "d", api_tokens=[TOKEN], stt_engine="fake")
    app = create_app(settings, engine_factory=Boom, diarizer_factory=Silent, start_worker=False)
    client = TestClient(app)
    client.headers["Authorization"] = f"Bearer {TOKEN}"
    put_audio(client, "s1", make_ogg(tmp_path / "a.opus"), transcribe="1")
    assert app.state.worker.drain() == 2
    seg = client.get("/api/v1/segments/s1").json()
    assert seg["server_stt_status"] == "done" and seg["has_speech"] is False
