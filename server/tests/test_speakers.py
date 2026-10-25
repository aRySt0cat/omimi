"""話者の指定・学習・「その人らしくない発話」の確認"""

import base64
import hashlib
import io
import wave

import numpy as np
from fastapi.testclient import TestClient
from test_api import TOKEN, metadata_header

from omi_home_server import speaker_model
from omi_home_server.app import create_app
from omi_home_server.config import Settings
from omi_home_server.diarize import Turn

SR = 16000
DIM = 8
# 声の高さ (Hz) → 声の特徴。テストでは純音の高さで話者を表す
VOICES = {440: np.eye(DIM)[0], 880: np.eye(DIM)[1], 1320: np.eye(DIM)[2]}


def make_tones(path, parts) -> bytes:
    """[(Hz または 0 = 無音, 秒), ...] をつないだ Ogg Opus"""
    import av

    pcm = np.concatenate([
        (0.3 * np.sin(2 * np.pi * f * np.arange(int(SR * sec)) / SR) if f else np.zeros(int(SR * sec)))
        for f, sec in parts])
    pcm = (pcm * 32767).astype(np.int16)
    with av.open(str(path), "w", format="ogg") as out:
        stream = out.add_stream("libopus", rate=SR)
        stream.layout = "mono"
        frame = av.AudioFrame.from_ndarray(pcm.reshape(1, -1), format="s16", layout="mono")
        frame.sample_rate = SR
        for packet in stream.encode(frame):
            out.mux(packet)
        for packet in stream.encode(None):
            out.mux(packet)
    return path.read_bytes()


def voice_of(clip: np.ndarray) -> np.ndarray:
    spectrum = np.abs(np.fft.rfft(clip))
    hz = np.argmax(spectrum) * SR / len(clip)
    base = VOICES[min(VOICES, key=lambda f: abs(f - hz))]
    # 同じ人でも発話ごとに少し揺らす
    noise = np.random.default_rng(len(clip)).normal(0, 0.15, DIM)
    v = base + noise
    return (v / np.linalg.norm(v)).astype(np.float32)


class ToneDiarizer:
    """録音ごとに決めた区間とラベルを返し、声の特徴は音の高さから作る"""
    plans: dict[int, list[Turn]] = {}

    def __init__(self, settings):
        pass

    def diarize(self, audio):
        return self.plans[len(audio) // SR]

    def speaker_embeddings(self, audio, turns):
        out = {}
        for label in {t.label for t in turns}:
            clips = np.concatenate([audio[int(t.start * SR):int(t.end * SR)] for t in turns if t.label == label])
            vecs = [voice_of(audio[int(t.start * SR):int(t.end * SR)]) for t in turns if t.label == label]
            v = np.mean(vecs, axis=0)
            out[label] = ((v / np.linalg.norm(v)).astype(np.float32), len(clips) / SR)
        return out

    def embed(self, clip):
        return voice_of(clip) if len(clip) >= SR // 2 else None


def put(client, seg_id, ogg, started_at):
    r = client.put(f"/api/v1/segments/{seg_id}/audio", content=ogg, headers={
        "Content-Type": "audio/ogg", "X-Omi-Metadata": metadata_header(seg_id, started_at=started_at),
        "X-Content-SHA256": hashlib.sha256(ogg).hexdigest(), "X-Omi-Transcribe": "0"})
    assert r.status_code == 200, r.text


def device_pieces(client, seg_id, pieces):
    r = client.put(f"/api/v1/segments/{seg_id}/device-transcript", json={
        "engine": "apple", "locale": "ja-JP", "pieces": [{"start": s, "end": e, "text": t} for s, e, t in pieces]})
    assert r.status_code == 200, r.text


def speakers_of(client, seg_id):
    return [(p["text"], p.get("speaker")) for p in client.get(f"/api/v1/segments/{seg_id}").json()["transcripts"][0]["pieces"]]


def make_client(tmp_path):
    settings = Settings(data_dir=tmp_path / "d", api_tokens=[TOKEN], stt_engine="none", timezone="Asia/Tokyo",
                        speaker_min_seconds=1.0)
    app = create_app(settings, diarizer_factory=ToneDiarizer, start_worker=False)
    client = TestClient(app)
    client.headers["Authorization"] = f"Bearer {TOKEN}"
    return client, app, settings


def test_learns_named_speakers_and_finds_odd_utterances(tmp_path):
    client, app, settings = make_client(tmp_path)
    worker = app.state.worker
    # 1, 2 本目: 自分 (440 Hz) と相手 (880 Hz) が交互に話す (6 秒)
    two = make_tones(tmp_path / "two.opus", [(440, 2), (0, 1), (880, 2), (0, 1)])
    ToneDiarizer.plans[6] = [Turn(0, 2, "S0"), Turn(3, 5, "S1")]
    put(client, "r1", two, "2026-10-10T01:00:00Z")
    put(client, "r2", two, "2026-10-10T02:00:00Z")
    worker.drain()
    speakers = {s["id"]: s for s in client.get("/api/v1/speakers").json()["speakers"]}
    assert len(speakers) == 2
    labels = app.state.db.speaker_map("r1")
    me, other = labels["S0"]["speaker_id"], labels["S1"]["speaker_id"]  # 440 Hz が自分
    client.patch(f"/api/v1/speakers/{me}", json={"name": "自分"})
    client.patch(f"/api/v1/speakers/{other}", json={"name": "田中"})
    assert worker.model_pending
    worker.drain()  # 名前を付けたので学習する
    model = worker.speaker_model
    assert model is not None and sorted(model.speaker_ids) == sorted([me, other])
    info = client.get("/api/v1/speakers").json()["model"]
    assert info["samples"] == 4 and {s["name"] for s in info["speakers"]} == {"自分", "田中"}
    assert all(s["learned"] for s in client.get("/api/v1/speakers").json()["speakers"])

    # 3 本目: 話者分離が 2 人を 1 つのラベルにまとめてしまった録音 (9 秒)
    #   → 学習したモデルで、発話ごとに自分 / 田中 に分け直す。1320 Hz の知らない声はラベルの話者のまま
    mixed = make_tones(tmp_path / "mixed.opus", [(440, 2), (0, 1.5), (880, 2), (0, 1.5), (1320, 2)])
    ToneDiarizer.plans[9] = [Turn(0, 2, "S0"), Turn(3.5, 5.5, "S0"), Turn(7, 9, "S0")]
    put(client, "r3", mixed, "2026-10-10T03:00:00Z")
    device_pieces(client, "r3", [(0.1, 1.9, "おはよう"), (3.6, 5.4, "元気?"), (7.1, 8.9, "どうも")])
    worker.drain()
    by_text = dict(speakers_of(client, "r3"))
    assert by_text["おはよう"] == "自分" and by_text["元気?"] == "田中"
    unknown_voice = by_text["どうも"]

    # ラベルの話者 (どちらとも決まらなかった人) の発話のうち、その人らしくないものが「確認したい発話」に出る
    label_speaker = next(s for s in client.get("/api/v1/speakers").json()["speakers"] if s["display_name"] == unknown_voice)
    # 自分の発話にほかの人の声が混ざったケース: 4 本目は自分のラベルに 1320 Hz が入っている
    odd = make_tones(tmp_path / "odd.opus", [(440, 3), (0, 1.5), (1320, 2), (0, 1.5), (440, 2)])
    ToneDiarizer.plans[10] = [Turn(0, 3, "S0"), Turn(4.5, 6.5, "S0"), Turn(8, 10, "S0")]
    put(client, "r4", odd, "2026-10-10T04:00:00Z")
    device_pieces(client, "r4", [(0.1, 2.9, "今日は"), (4.6, 6.4, "知らない声"), (8.1, 9.9, "以上")])
    worker.drain()
    assert dict(speakers_of(client, "r4"))["今日は"] == "自分"
    review = client.get(f"/api/v1/speakers/{me}/utterances").json()
    assert [u["text"] for u in review["utterances"]] == ["知らない声"]
    odd_u = review["utterances"][0]
    assert odd_u["suspicious"] and odd_u["score"] < review["threshold"] and odd_u["segment_id"] == "r4"
    assert odd_u["at"] == "2026-10-10T04:00:04Z"
    me_row = next(s for s in client.get("/api/v1/speakers").json()["speakers"] if s["id"] == me)
    assert me_row["suspicious"] == 1 and me_row["utterances"] >= 4

    # 確かめるための音声
    wav = client.get("/api/v1/segments/r4/clip", params={"start": odd_u["start"], "end": odd_u["end"], "pad": 0})
    with wave.open(io.BytesIO(wav.content)) as w:
        assert w.getframerate() == SR and abs(w.getnframes() / SR - (odd_u["end"] - odd_u["start"])) < 0.05

    # 正しい人に直す (新しい名前なら、その発話の声で話者を作る)
    r = client.put(f"/api/v1/utterances/{odd_u['id']}", json={"name": "佐藤"})
    assert r.status_code == 200, r.text
    assert dict(speakers_of(client, "r4"))["知らない声"] == "佐藤"
    piece = next(p for p in client.get("/api/v1/segments/r4").json()["transcripts"][0]["pieces"] if p["text"] == "知らない声")
    assert piece["speaker_manual"] is True and piece["utterance_id"] == odd_u["id"]
    assert client.get(f"/api/v1/speakers/{me}/utterances").json()["utterances"] == []
    worker.drain()  # 学習し直すと、佐藤さんもモデルに入る
    assert any(s["name"] == "佐藤" for s in worker.speaker_model.info["speakers"])
    # 3 本目の 1320 Hz も、学習し直したので佐藤さんになる
    assert dict(speakers_of(client, "r3"))["どうも"] == "佐藤"
    assert label_speaker["display_name"] == unknown_voice

    # 合っていると確認した発話は、確認済みとして数える
    first = client.get(f"/api/v1/speakers/{me}/utterances", params={"filter": "all"}).json()["utterances"][0]
    assert client.put(f"/api/v1/utterances/{first['id']}", json={"confirm": True}).json()["speaker_id"] == me
    confirmed = client.get(f"/api/v1/speakers/{me}/utterances", params={"filter": "confirmed"}).json()["utterances"]
    assert [u["id"] for u in confirmed] == [first["id"]] and confirmed[0]["manual"]

    # iPhone に渡す学習済みの声 (iPhone で話者分離したときに名前を当てる)
    voices = client.get("/api/v1/speakers/voices").json()
    assert voices["source"] == "server" and voices["settings"]["min_seconds"] == 1.0
    by_id = {p["id"]: p for p in voices["profiles"]}
    assert by_id[me]["name"] == "自分" and by_id[other]["name"] == "田中"
    vec = np.frombuffer(base64.b64decode(by_id[me]["vector"]), dtype="<f4")
    assert vec.shape == (DIM,) and abs(np.linalg.norm(vec) - 1) < 1e-4
    m = voices["model"]
    assert sorted(m["speaker_ids"]) == sorted(worker.speaker_model.speaker_ids)
    assert len(m["centroids"]) == len(m["speaker_ids"]) == len(m["thresholds"]) == len(m["review"])
    assert client.get("/api/v1/speakers/voices", params={"since": voices["version"]}).json() == \
        {"version": voices["version"], "unchanged": True}

    # 学習したモデルは保存され、次に起動したときも使う
    assert (settings.data_dir / "speaker_model.npz").exists()
    app2 = create_app(settings, diarizer_factory=ToneDiarizer, start_worker=False)
    assert sorted(app2.state.worker.speaker_model.speaker_ids) == sorted(worker.speaker_model.speaker_ids)


def test_assign_range_and_reassign(tmp_path):
    client, app, settings = make_client(tmp_path)
    worker = app.state.worker
    two = make_tones(tmp_path / "two.opus", [(440, 2), (0, 1), (880, 2), (0, 1)])
    ToneDiarizer.plans[6] = [Turn(0, 2, "S0"), Turn(3, 5, "S1")]
    put(client, "r1", two, "2026-10-10T01:00:00Z")
    device_pieces(client, "r1", [(0.1, 1.9, "あ"), (3.1, 4.9, "い")])
    worker.drain()
    before = dict(speakers_of(client, "r1"))
    first_speaker = app.state.db.speaker_map("r1")["S0"]["speaker_id"]

    # 発話をタップして話者を指定する (時間の範囲で)
    r = client.put("/api/v1/segments/r1/utterances", json={"start": 3.1, "end": 4.9, "name": "田中"})
    assert r.status_code == 200, r.text
    tanaka = r.json()["speaker_id"]
    assert dict(speakers_of(client, "r1")) == {"あ": before["あ"], "い": "田中"}
    # 同じ範囲をもう一度指定すると置き換える。不明にもできる
    client.put("/api/v1/segments/r1/utterances", json={"start": 3.0, "end": 5.0, "unknown": True})
    assert dict(speakers_of(client, "r1"))["い"] is None
    assert len([u for u in app.state.db.utterances_for("r1") if u["manual"]]) == 1
    # 短すぎる範囲に新しい名前は付けられない (声の特徴が取れない) が、既にいる人なら付けられる
    assert client.put("/api/v1/segments/r1/utterances", json={"start": 5.5, "end": 5.8, "name": "新人"}).status_code == 409
    assert client.put("/api/v1/segments/r1/utterances", json={"start": 3.1, "end": 4.9, "speaker_id": tanaka}).status_code == 200
    assert client.put("/api/v1/segments/r1/utterances", json={"start": 3.1, "end": 4.9}).status_code == 400
    assert client.put("/api/v1/segments/r1/utterances", json={"start": 3.1, "end": 4.9, "speaker_id": 999}).status_code == 404

    # 録音の中の、ある話者を丸ごと付け替える (その人に指定した発話も一緒に)
    r = client.post("/api/v1/segments/r1/reassign", json={"from_speaker_id": first_speaker, "name": "自分"})
    assert r.status_code == 200 and r.json()["labels"] == 1
    assert dict(speakers_of(client, "r1")) == {"あ": "自分", "い": "田中"}
    assert app.state.db.speaker_map("r1")["S0"]["speaker_id"] == r.json()["speaker_id"]
    assert client.post("/api/v1/segments/r1/reassign", json={"from_speaker_id": 999, "name": "x"}).status_code == 404

    # 手で指定したラベルは、学習し直しても変えない
    report = client.post("/api/v1/speakers/train").json()
    assert report["model"]["samples"] >= 1
    assert dict(speakers_of(client, "r1")) == {"あ": "自分", "い": "田中"}
    assert client.get("/api/v1/segments/r1/clip", params={"start": 3, "end": 2}).status_code == 400

    # 話し声の区間と重ならない 1 秒以上の範囲にも、新しい名前を付けられる。
    # 名前を先に作り、声の特徴はワーカーがその範囲の音声から埋める
    other = make_tones(tmp_path / "other.opus", [(1320, 3), (0, 3)])
    ToneDiarizer.plans[6] = []
    put(client, "r2", other, "2026-10-10T02:00:00Z")
    worker.drain()
    r = client.put("/api/v1/segments/r2/utterances", json={"start": 0.5, "end": 2.5, "name": "山田"})
    assert r.status_code == 200, r.text
    yamada = r.json()["speaker_id"]
    assert np.linalg.norm(next(v for i, v, _w in app.state.db.speaker_profiles() if i == yamada)) == 0
    worker.drain()
    assert np.linalg.norm(next(v for i, v, _w in app.state.db.speaker_profiles() if i == yamada)) > 0.9


def test_training_prefers_projection_only_when_it_helps():
    rng = np.random.default_rng(0)
    dim = 16
    centers = rng.normal(0, 1, (3, dim)) * 0.6
    # 1 つの次元だけ大きく揺れる (話者に関係ない揺れ) → 白色化で抑えると当たりやすくなる
    samples = []
    for k in range(3):
        for _ in range(12):
            v = centers[k] + rng.normal(0, 0.3, dim)
            v[0] += rng.normal(0, 5.0)
            samples.append(speaker_model.Sample(v / np.linalg.norm(v), 10 + k, 3.0, True))

    class FakeDb:
        def named_speakers(self):
            return {10: "a", 11: "b", 12: "c"}

    original = speaker_model.collect_samples
    speaker_model.collect_samples = lambda db: samples
    try:
        model = speaker_model.train(FakeDb())
    finally:
        speaker_model.collect_samples = original
    assert model is not None and model.speaker_ids == [10, 11, 12]
    assert model.info["projection"] is True and model.info["accuracy"] >= 0.9
    for k in range(3):
        best, score = model.confident(samples[k * 12].embedding)
        assert best == 10 + k and score >= model.threshold(10 + k)
    # 「その人らしくない」とする発話は、本人の発話の一部だけ
    for k in range(3):
        own = [model.scores(s.embedding)[10 + k] for s in samples[k * 12:(k + 1) * 12]]
        assert sum(score < model.review_threshold(10 + k) for score in own) <= 3


def test_other_voices_are_lumped_and_candidates(tmp_path):
    """名前のない声は「その他」。よく聞く声だけを名前を付ける候補にし、声ごとまとめて名前を付けられる"""
    client, app, settings = make_client(tmp_path)
    worker = app.state.worker
    two = make_tones(tmp_path / "two.opus", [(440, 2), (0, 1), (880, 2), (0, 1)])
    ToneDiarizer.plans[6] = [Turn(0, 2, "S0"), Turn(3, 5, "S1")]
    for i, day in enumerate(["2026-10-09", "2026-10-10", "2026-10-11"]):
        put(client, f"r{i}", two, f"{day}T01:00:00Z")
        device_pieces(client, f"r{i}", [(0.1, 1.9, "はい"), (3.1, 4.9, "次は渋谷")])
    worker.drain()
    labels = app.state.db.speaker_map("r0")
    me, announce = labels["S0"]["speaker_id"], labels["S1"]["speaker_id"]
    assert dict(speakers_of(client, "r0")) == {"はい": "その他", "次は渋谷": "その他"}
    rows = {s["id"]: s for s in client.get("/api/v1/speakers").json()["speakers"]}
    assert rows[me]["candidate"] and rows[announce]["candidate"] and rows[me]["days"] == 3
    assert not rows[me]["named"] and rows[me]["display_name"] == "その他"

    # 1 つの発話から、この声のすべての録音に名前を付ける
    assert client.post(f"/api/v1/speakers/{me}/assign", json={"name": "自分"}).status_code == 200
    assert [dict(speakers_of(client, f"r{i}"))["はい"] for i in range(3)] == ["自分"] * 3
    # アナウンスの声は「その他」にする (候補から外れる)
    assert client.post(f"/api/v1/speakers/{announce}/assign", json={"unknown": True}).status_code == 200
    rows = {s["id"]: s for s in client.get("/api/v1/speakers").json()["speakers"]}
    assert rows[announce]["ignored"] and not rows[announce]["candidate"]
    assert dict(speakers_of(client, "r1"))["次は渋谷"] == "その他"

    # 「その他」は名前に使えない。同じ名前の人がいるときはまとめる案内
    assert client.patch(f"/api/v1/speakers/{announce}", json={"name": "その他"}).status_code == 400
    assert client.patch(f"/api/v1/speakers/{announce}", json={"name": "自分"}).status_code == 409
    # 発話に「その他」を指定すると話者なし (画面では「その他」と表示) になる
    r = client.put("/api/v1/segments/r2/utterances", json={"start": 0.1, "end": 1.9, "name": "その他"})
    assert r.json()["speaker_id"] is None and dict(speakers_of(client, "r2"))["はい"] is None
    # 既にいる人の名前で声を指定すると、その人にまとめる
    client.patch(f"/api/v1/speakers/{announce}", json={"ignored": False})
    assert client.post(f"/api/v1/speakers/{announce}/assign", json={"name": "自分"}).json()["speaker_id"] == me
    assert len(client.get("/api/v1/speakers").json()["speakers"]) == 1

    # 学習では「その他」の声を他人の例として使う
    worker.drain()
    assert "background" in worker.speaker_model.info
