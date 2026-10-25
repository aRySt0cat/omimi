"""文字起こしの聞き比べ (Apple と Whisper を目隠しで並べ、人が選ぶ)"""

import json

from test_api import env, put_audio  # noqa: F401  (fixture)

from omi_home_server import compare
from omi_home_server.exporter import choose_transcript


def setup_pair(client, app, ogg, seg="c1"):
    assert put_audio(client, seg, ogg).status_code in (200, 201)
    client.put(f"/api/v1/segments/{seg}/device-transcript", json={
        "engine": "apple-speech", "locale": "ja-JP", "pieces": [
            {"start": 0.0, "end": 2.0, "text": "下河内さんおはよう"},
            {"start": 2.5, "end": 4.0, "text": "今日は晴れ"},
            {"start": 9.0, "end": 9.8, "text": "はい"},  # Whisper が書かなかった範囲
        ]})
    app.state.db.put_transcript(seg, "server", engine="faster-whisper:large-v3-turbo", locale="ja", pieces=[
        {"start": 0.0, "end": 2.1, "text": "下河内さん、おはよう。"},  # 句読点だけの違い = 同じ
        {"start": 2.4, "end": 4.1, "text": "今日は春"},
        {"start": 6.0, "end": 7.0, "text": "ご視聴ありがとうございました"},  # Apple が書かなかった範囲
    ])


def test_pairs_are_blind_and_votes_map_back(env):  # noqa: F811
    client, app, ogg, _ = env
    setup_pair(client, app, ogg)
    pairs = compare.pairs_for("c1", app.state.db.transcripts_for("c1"))
    assert [(p["start"], p["identical"]) for p in pairs] == [(0.0, True), (2.4, False), (6.0, False), (9.0, False)]
    assert pairs[2]["apple"] == "" and pairs[3]["whisper"] == ""

    r = client.get("/api/v1/compare/stt").json()
    # 同じ文字起こしの範囲は聞かなくてよい
    assert {p["id"] for p in r["pairs"]} == {"c1@2.40", "c1@6.00", "c1@9.00"} and r["remaining"] == 3
    sm = r["summary"]
    assert sm["pairs"] == 4 and sm["identical"] == 1 and sm["only_apple"] == 1 and sm["only_whisper"] == 1
    assert sm["preference"] == "whisper" and sm["verdict"] is None
    shown = next(p for p in r["pairs"] if p["id"] == "c1@2.40")
    assert {shown["a"], shown["b"]} == {"今日は晴れ", "今日は春"}
    assert "apple" not in shown and "whisper" not in shown  # どちらのものかは伏せる

    # 「晴れ」の方を選ぶと、Apple の勝ちとして数える (A/B のどちらに出ていても)
    choice = "a" if shown["a"] == "今日は晴れ" else "b"
    v = client.post("/api/v1/compare/stt/vote", json={"id": "c1@2.40", "choice": choice}).json()
    assert v["winner"] == "apple" and v["summary"]["votes"]["apple"] == 1
    client.post("/api/v1/compare/stt/vote", json={"id": "c1@6.00", "choice": "neither"})
    assert client.get("/api/v1/compare/stt").json()["remaining"] == 1
    # 取り消し・選び直し
    assert client.delete("/api/v1/compare/stt/vote/c1@6.00").json()["votes"]["neither"] == 0
    assert client.post("/api/v1/compare/stt/vote", json={"id": "c1@9.99", "choice": "a"}).status_code == 404
    assert client.post("/api/v1/compare/stt/vote", json={"id": "c1@2.40", "choice": "x"}).status_code == 400


def test_verdict_and_preference(env):  # noqa: F811
    client, app, ogg, settings = env
    db = app.state.db
    setup_pair(client, app, ogg)
    # 投票が集まると判断が出る (Apple 15 : Whisper 5)
    with db.tx() as c:
        for i in range(20):
            c.execute("INSERT INTO stt_votes VALUES (?, 'c1', 0, 1, '', '', ?, '2026-10-13T00:00:00Z')",
                      (f"x{i}", "apple" if i < 15 else "whisper"))
    sm = compare.summary(db)
    assert sm["decided"] == 20 and sm["verdict"] == "apple"

    # Apple を使うことにすると、書き出しと AI に渡す文字起こしが端末のものになる
    r = client.put("/api/v1/compare/stt/preference", json={"preference": "apple"})
    assert r.status_code == 200 and r.json()["preference"] == "apple"
    assert choose_transcript(db.transcripts_for("c1"), compare.preference(db))["origin"] == "device"
    assert choose_transcript(db.transcripts_for("c1"))["origin"] == "server"
    app.state.worker.flush_exports()
    day = next((settings.data_dir / "timeline").glob("*.jsonl"))
    seg = next(json.loads(line) for line in day.read_text().splitlines() if '"segment"' in line)
    assert seg["transcript_source"] == "device"
    assert client.put("/api/v1/compare/stt/preference", json={"preference": "x"}).status_code == 400


def test_iphone_writes_notes_and_gets_materials(env):  # noqa: F811
    """iPhone が自分で ChatGPT に頼むとき: 指示と添付を受け取り、書いたまとめを置く (自宅サーバは OpenAI と通信しない)"""
    client, app, ogg, settings = env
    setup_pair(client, app, ogg)
    r = client.get("/api/v1/ai/materials", params={"day": "2026-10-10"})
    assert r.status_code == 200, r.text
    m = r.json()
    assert m["note"] == "2026-10-10.md" and "<<<NOTE>>>" in m["instructions"] and "10月10日" in m["instructions"]
    assert '<file path="timeline/2026-10-10.md">' in m["materials"] and '<file path="AGENTS.md">' in m["materials"]
    assert client.get("/api/v1/ai/materials", params={"day": "2026-01-01"}).status_code == 404
    assert client.get("/api/v1/ai/materials", params={"day": "x"}).status_code == 400

    text = "# 10月10日 (土)\n\n> 打ち合わせの日。\n"
    e = client.put("/api/v1/notes/2026-10-10.md", json={"text": text, "agent": "chatgpt:gpt-test@iphone"}).json()
    assert e["kind"] == "day" and e["summary"] == "打ち合わせの日。"
    assert client.get("/api/v1/notes/2026-10-10.md").json()["text"] == text
    assert client.put("/api/v1/notes/todo.md", json={"text": "# やること\n"}).status_code == 200
    assert client.put("/api/v1/notes/people/a.md", json={"text": "x"}).status_code == 400
    assert client.put("/api/v1/notes/../x.md", json={"text": "x"}).status_code in (400, 404)
    runs = (settings.data_dir / "runs" / "nightly.jsonl").read_text().splitlines()
    assert json.loads(runs[-1])["agent"] == "chatgpt:gpt-test@iphone"
