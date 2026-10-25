"""用語集: 登録・文字起こしのヒント・表示と書き出しの補正・AI への添付"""

import json

from fastapi.testclient import TestClient
from test_api import TOKEN, FakeDiarizer, make_ogg, put_audio

from omi_home_server import nightly
from omi_home_server.app import create_app
from omi_home_server.config import Settings
from omi_home_server.stt import Piece
from omi_home_server.vocabulary import Vocabulary


class RecordingEngine:
    """受け取ったヒントを覚え、よく間違う表記で返す"""
    name = "fake"
    model = "m1"
    hotwords: list = []

    def __init__(self, settings):
        pass

    def transcribe(self, audio, language=None, hotwords=None):
        RecordingEngine.hotwords.append(hotwords)
        return [Piece(0.0, len(audio) / 16000, "しもがうちさんとオミの話", language)]

    def detect_language(self, audio, candidates):
        return "ja", 0.9


def test_correct_and_hotwords():
    v = Vocabulary([{"term": "下河内", "reading": "しもがうち", "aliases": ["しもがうち", "下川内", "下"]},
                    {"term": "Omi", "aliases": ["オミ", "オミー"]}])
    assert v.correct("しもがうちさんとオミーとオミ") == "下河内さんとOmiとOmi"
    assert v.correct("下の階") == "下の階"  # 1 文字の表記は置き換えない
    assert v.hotwords() == "下河内 Omi"
    md = v.markdown()
    assert "| 下河内 | しもがうち | しもがうち、下川内、下 |" in md
    assert not Vocabulary([]) and Vocabulary([]).hotwords() is None


def test_vocabulary_api_and_effects(tmp_path):
    settings = Settings(data_dir=tmp_path / "d", api_tokens=[TOKEN], stt_engine="fake", timezone="Asia/Tokyo",
                        transcribe_policy="always")
    app = create_app(settings, engine_factory=RecordingEngine, diarizer_factory=FakeDiarizer, start_worker=False)
    client = TestClient(app)
    client.headers["Authorization"] = f"Bearer {TOKEN}"

    r = client.post("/api/v1/vocabulary", json={"term": " 下河内 ", "reading": "しもがうち",
                                                 "aliases": ["しもがうち", "しもがうち", "下河内", " "], "note": "同僚"})
    assert r.status_code == 200, r.text
    entry = r.json()
    assert entry["term"] == "下河内" and entry["aliases"] == ["しもがうち"] and entry["note"] == "同僚"
    assert client.post("/api/v1/vocabulary", json={"term": "下河内"}).status_code == 409
    omi = client.post("/api/v1/vocabulary", json={"term": "Omi", "aliases": ["オミ"]}).json()
    assert [v["term"] for v in client.get("/api/v1/vocabulary").json()["vocabulary"]] == ["下河内", "Omi"]
    assert (settings.data_dir / "vocabulary.md").read_text().startswith("# 用語集")

    # サーバの文字起こしにヒントを渡し、表示・書き出しでは正しい表記に直す (元の文字起こしも残す)
    put_audio(client, "s1", make_ogg(tmp_path / "a.opus"), transcribe="1")
    app.state.worker.drain()
    assert RecordingEngine.hotwords and RecordingEngine.hotwords[-1] == "下河内 Omi"
    piece = [t for t in client.get("/api/v1/segments/s1").json()["transcripts"] if t["origin"] == "server"][0]["pieces"][0]
    assert piece["text"] == "下河内さんとOmiの話" and piece["original_text"] == "しもがうちさんとオミの話"
    md = (settings.data_dir / "timeline/2026-10-10.md").read_text()
    assert "下河内さんとOmiの話" in md
    jsonl = [json.loads(x) for x in (settings.data_dir / "timeline/2026-10-10.jsonl").read_text().splitlines()]
    assert any(r.get("text") == "下河内さんとOmiの話" for r in jsonl)

    # 変更・削除
    assert client.put(f"/api/v1/vocabulary/{omi['id']}", json={"term": "Omi", "aliases": []}).json()["aliases"] == []
    assert client.put("/api/v1/vocabulary/999", json={"term": "x"}).status_code == 404
    assert client.put(f"/api/v1/vocabulary/{omi['id']}", json={"term": "下河内"}).status_code == 409
    piece = [t for t in client.get("/api/v1/segments/s1").json()["transcripts"] if t["origin"] == "server"][0]["pieces"][0]
    assert piece["text"] == "下河内さんとオミの話"
    assert client.delete(f"/api/v1/vocabulary/{entry['id']}").status_code == 200
    assert client.delete(f"/api/v1/vocabulary/{omi['id']}").status_code == 200
    assert not (settings.data_dir / "vocabulary.md").exists()


def test_vocabulary_is_attached_for_ai(tmp_path):
    data = tmp_path / "d"
    (data / "timeline").mkdir(parents=True)
    (data / "timeline/2026-10-10.md").write_text("# 会話\n")
    (data / "vocabulary.md").write_text("# 用語集\n| 下河内 |\n")
    text = nightly.chatgpt_materials(data, __import__("datetime").date(2026, 10, 10), None)
    assert '<file path="vocabulary.md">' in text and "下河内" in text
    assert "vocabulary.md" in (nightly.PROMPT_TEMPLATE.read_text())
