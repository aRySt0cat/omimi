"""Sign in with ChatGPT と、ChatGPT での「AI で整理する」 (OpenAI 側は偽物に差し替える)"""

import base64
import hashlib
import json
import os
import stat
import time
from datetime import date
from urllib.parse import parse_qs, urlsplit

import httpx
import pytest
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import padding, rsa
from fastapi.testclient import TestClient
from test_api import TOKEN, FakeDiarizer, FakeEngine, make_ogg, put_audio

from omi_home_server import nightly
from omi_home_server.app import create_app
from omi_home_server.chatgpt import PLAN_SCOPE, SCOPES, ChatGPT, ChatGPTError
from omi_home_server.config import Settings

ISSUER = "https://auth.openai.com"


def b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


class FakeOpenAI:
    """auth.openai.com と api.openai.com の代わり"""

    def __init__(self):
        self.key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        self.other_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        self.requests: list[httpx.Request] = []
        self.nonce = None
        self.client_id = "oaiapp_test123"
        self.refresh_count = 0
        self.refresh_error = None
        self.sign_with_other = False
        self.scope = SCOPES
        self.stream_events = None
        self.stream_status = 200
        self.revoked = []

    def id_token(self, aud, nonce=None, sub="user-1", email="me@example.com"):
        header = {"alg": "RS256", "kid": "k1", "typ": "JWT"}
        claims = {"iss": ISSUER, "aud": aud, "sub": sub, "email": email, "exp": time.time() + 3600, "iat": time.time()}
        if nonce:
            claims["nonce"] = nonce
        signing = f"{b64(json.dumps(header).encode())}.{b64(json.dumps(claims).encode())}".encode()
        key = self.other_key if self.sign_with_other else self.key
        sig = key.sign(signing, padding.PKCS1v15(), hashes.SHA256())
        return f"{signing.decode()}.{b64(sig)}"

    def jwks(self):
        n = self.key.public_key().public_numbers()
        return {"keys": [{"kty": "RSA", "kid": "k1", "alg": "RS256", "use": "sig",
                          "n": b64(n.n.to_bytes((n.n.bit_length() + 7) // 8, "big")),
                          "e": b64(n.e.to_bytes((n.e.bit_length() + 7) // 8, "big"))}]}

    def handler(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        url = str(request.url)
        if url == f"{ISSUER}/.well-known/openid-configuration":
            return httpx.Response(200, json={"issuer": ISSUER, "jwks_uri": f"{ISSUER}/.well-known/jwks.json",
                                             "revocation_endpoint": f"{ISSUER}/oauth/revoke"})
        if url == f"{ISSUER}/.well-known/jwks.json":
            return httpx.Response(200, json=self.jwks())
        if url == f"{ISSUER}/api/accounts/oauth/token":
            form = {k: v[0] for k, v in parse_qs(request.content.decode()).items()}
            self.last_form = form
            if form["grant_type"] == "authorization_code":
                return httpx.Response(200, json={
                    "access_token": "at-1", "refresh_token": "rt-1", "token_type": "Bearer", "expires_in": 3600,
                    "scope": self.scope, "id_token": self.id_token(form["client_id"], self.nonce)})
            if self.refresh_error:
                return httpx.Response(400, json={"error": self.refresh_error})
            self.refresh_count += 1
            n = self.refresh_count + 1
            return httpx.Response(200, json={"access_token": f"at-{n}", "refresh_token": f"rt-{n}", "expires_in": 3600,
                                             "token_type": "Bearer", "scope": self.scope})
        if url == f"{ISSUER}/oauth/revoke":
            self.revoked.append({k: v[0] for k, v in parse_qs(request.content.decode()).items()})
            return httpx.Response(200)
        if url == "https://api.openai.com/v1/models":
            return httpx.Response(200, json={"models": [
                {"slug": "gpt-test", "display_name": "GPT Test", "visibility": "list"},
                {"slug": "hidden", "display_name": "Hidden", "visibility": "hide"}]})
        if url == "https://api.openai.com/v1/responses":
            self.last_body = json.loads(request.content)
            if self.stream_status != 200:
                return httpx.Response(self.stream_status, json=self.stream_events)
            events = self.stream_events or [
                {"type": "response.created"},
                {"type": "response.output_text.delta", "delta": "こん"},
                {"type": "response.output_text.delta", "delta": "にちは"},
                {"type": "response.completed", "response": {}},
            ]
            body = "".join(f"event: {e['type']}\ndata: {json.dumps(e, ensure_ascii=False)}\n\n" for e in events)
            return httpx.Response(200, content=body.encode(), headers={"Content-Type": "text/event-stream"})
        return httpx.Response(404, json={"error": "not found"})


@pytest.fixture
def fake():
    return FakeOpenAI()


def make_gpt(tmp_path, fake, **kw):
    return ChatGPT(tmp_path / "data", transport=httpx.MockTransport(fake.handler), open_listener=False, **kw)


def sign_in(gpt, fake):
    start = gpt.start_login()
    q = {k: v[0] for k, v in parse_qs(urlsplit(start["authorize_url"]).query).items()}
    fake.nonce = q["nonce"]
    url = f"{start['redirect_uri']}?code=c1&state={q['state']}&client_id={fake.client_id}&scope=x"
    return gpt.complete_from_url(url), q


def test_authorize_url_follows_the_spec(tmp_path, fake):
    gpt = make_gpt(tmp_path, fake)
    start = gpt.start_login()
    parts = urlsplit(start["authorize_url"])
    assert f"{parts.scheme}://{parts.netloc}{parts.path}" == "https://auth.openai.com/api/accounts/authorize"
    q = {k: v[0] for k, v in parse_qs(parts.query).items()}
    assert q["client_id"] == "dynamic_agent_client" and q["agent_name_hint"] == "Omimi"
    assert q["ext_agent_host_id"].startswith("urn:uuid:") and q["response_type"] == "code"
    assert q["redirect_uri"] == "http://127.0.0.1:1455/auth/callback" == start["redirect_uri"]
    assert q["scope"] == "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    assert q["resource"] == "https://api.openai.com/v1" and q["code_challenge_method"] == "S256"
    verifier = gpt._pending["verifier"]
    assert q["code_challenge"] == b64(hashlib.sha256(verifier.encode()).digest())
    assert len(q["state"]) > 20 and len(q["nonce"]) > 20 and "id_token_hint" not in q
    # ホスト ID は変わらない
    assert gpt.host_id() == q["ext_agent_host_id"] == ChatGPT(tmp_path / "data").host_id()


def test_sign_in_saves_protected_credentials(tmp_path, fake):
    gpt = make_gpt(tmp_path, fake)
    status, q = sign_in(gpt, fake)
    assert status["connected"] and status["plan_usage"] and status["email"] == "me@example.com"
    assert status["welcome"] and not status["pending"]
    form = fake.last_form
    assert form == {"grant_type": "authorization_code", "client_id": "oaiapp_test123", "code": "c1",
                    "code_verifier": form["code_verifier"], "redirect_uri": q["redirect_uri"],
                    "resource": "https://api.openai.com/v1"}
    assert b64(hashlib.sha256(form["code_verifier"].encode()).digest()) == q["code_challenge"]
    cred = gpt.credentials()
    assert cred["client_id"] == "oaiapp_test123" and cred["refresh_token"] == "rt-1" and cred["subject"] == "user-1"
    assert PLAN_SCOPE in cred["scopes"] and cred["ext_agent_host_id"] == q["ext_agent_host_id"]
    path = tmp_path / "data/chatgpt/auth.json"
    assert stat.S_IMODE(os.stat(path).st_mode) == 0o600
    assert stat.S_IMODE(os.stat(path.parent).st_mode) == 0o700
    gpt.dismiss_welcome()
    assert not gpt.status()["welcome"]

    # 2 回目は登録済みの client_id で、同じアカウントにサインインし直す
    start = gpt.start_login()
    q2 = {k: v[0] for k, v in parse_qs(urlsplit(start["authorize_url"]).query).items()}
    assert q2["client_id"] == "oaiapp_test123" and "agent_name_hint" not in q2
    assert q2["id_token_hint"] == cred["id_token"] and q2["login_hint"] == "me@example.com"
    assert q2["ext_agent_host_id"] == q["ext_agent_host_id"]


def test_rejects_bad_callbacks(tmp_path, fake):
    gpt = make_gpt(tmp_path, fake)
    with pytest.raises(ChatGPTError, match="サインインの受付が終わっています"):
        gpt.complete_from_url("http://127.0.0.1:1455/auth/callback?code=c&state=s")
    start = gpt.start_login()
    q = {k: v[0] for k, v in parse_qs(urlsplit(start["authorize_url"]).query).items()}
    with pytest.raises(ChatGPTError, match="state"):
        gpt.complete_from_url(f"{start['redirect_uri']}?code=c&state=wrong&client_id=oaiapp_x")
    with pytest.raises(ChatGPTError, match="client_id"):
        gpt.complete_from_url(f"{start['redirect_uri']}?code=c&state={q['state']}&client_id=dynamic_agent_client")
    with pytest.raises(ChatGPTError, match="入っていません"):
        gpt.complete_from_url("http://127.0.0.1:1455/auth/callback")
    # 署名が違う ID トークンは受け付けない
    fake.nonce = q["nonce"]
    fake.sign_with_other = True
    with pytest.raises(ChatGPTError, match="署名"):
        gpt.complete_from_url(f"{start['redirect_uri']}?code=c&state={q['state']}&client_id=oaiapp_x")
    assert not gpt.status()["connected"] and gpt.status()["error"]
    # 許可しなかった
    start = gpt.start_login()
    q = {k: v[0] for k, v in parse_qs(urlsplit(start["authorize_url"]).query).items()}
    with pytest.raises(ChatGPTError, match="取り消されました"):
        gpt.complete_from_url(f"{start['redirect_uri']}?error=access_denied&state={q['state']}")
    assert not gpt.status()["pending"]


def test_without_plan_scope_does_not_call_ai(tmp_path, fake):
    gpt = make_gpt(tmp_path, fake)
    fake.scope = "openid profile email offline_access"
    status, _ = sign_in(gpt, fake)
    assert status["connected"] and not status["plan_usage"]
    with pytest.raises(ChatGPTError, match="プランの利用が許可されていません"):
        gpt.respond(model="gpt-test", instructions="x", text="y")


def test_refresh_rotates_tokens_and_handles_revocation(tmp_path, fake):
    now = [time.time()]
    gpt = make_gpt(tmp_path, fake, clock=lambda: now[0])
    sign_in(gpt, fake)
    assert gpt.access_token() == "at-1" and fake.refresh_count == 0
    now[0] += 3600  # 期限切れ
    assert gpt.access_token() == "at-2"
    assert fake.last_form == {"grant_type": "refresh_token", "client_id": "oaiapp_test123", "refresh_token": "rt-1",
                              "resource": "https://api.openai.com/v1"}
    assert gpt.credentials()["refresh_token"] == "rt-2"
    # 別のプロセスが先に更新していれば、それを使う (二重に更新しない)
    other = make_gpt(tmp_path, fake, clock=lambda: now[0])
    assert other.access_token() == "at-2" and fake.refresh_count == 1
    # 更新できない (取り消された) ときは、登録は残してトークンだけ消す
    now[0] += 3600
    fake.refresh_error = "invalid_grant"
    with pytest.raises(ChatGPTError) as e:
        gpt.access_token()
    assert e.value.reconnect and not gpt.status()["connected"] and gpt.status()["registered"]


def test_sign_out_revokes_refresh_token(tmp_path, fake):
    gpt = make_gpt(tmp_path, fake)
    sign_in(gpt, fake)
    assert gpt.sign_out() is True
    assert fake.revoked == [{"token": "rt-1", "token_type_hint": "refresh_token", "client_id": "oaiapp_test123"}]
    cred = gpt.credentials()
    assert "access_token" not in cred and "refresh_token" not in cred and cred["client_id"] == "oaiapp_test123"


def test_responses_stream_and_errors(tmp_path, fake):
    gpt = make_gpt(tmp_path, fake)
    sign_in(gpt, fake)
    deltas = []
    assert gpt.respond(model="gpt-test", instructions="指示", text="本文", on_delta=deltas.append) == "こんにちは"
    assert deltas == ["こん", "にちは"]
    body = fake.last_body
    assert body["store"] is False and body["stream"] is True and body["model"] == "gpt-test"
    assert body["instructions"] == "指示" and body["input"][0]["content"][0]["text"] == "本文"
    auth = [r for r in fake.requests if str(r.url).endswith("/responses")][-1].headers["authorization"]
    assert auth == "Bearer at-1"
    assert gpt.list_models() == [{"slug": "gpt-test", "display_name": "GPT Test"}]

    fake.stream_events = [{"type": "response.output_text.delta", "delta": "途中"},
                          {"type": "response.failed", "response": {"error": {"code": "subscription_sharing_usage_limit_exceeded"}}}]
    with pytest.raises(ChatGPTError) as e:
        gpt.respond(model="gpt-test", instructions="x", text="y")
    assert e.value.code == "subscription_sharing_usage_limit_exceeded" and "使用量" in e.value.message
    fake.stream_events = [{"type": "response.output_text.delta", "delta": "途中"}]
    with pytest.raises(ChatGPTError, match="途中で切れました"):
        gpt.respond(model="gpt-test", instructions="x", text="y")
    fake.stream_status, fake.stream_events = 401, {"detail": "nope"}
    with pytest.raises(ChatGPTError) as e:
        gpt.respond(model="gpt-test", instructions="x", text="y")
    assert e.value.reconnect


def test_loopback_listener_completes_sign_in(tmp_path, fake):
    gpt = ChatGPT(tmp_path / "data", transport=httpx.MockTransport(fake.handler))
    start = gpt.start_login(return_url="http://100.64.0.1:8000/#/notes")
    try:
        assert start["redirect_uri"].startswith("http://127.0.0.1:14") and gpt.status()["listening"]
        q = {k: v[0] for k, v in parse_qs(urlsplit(start["authorize_url"]).query).items()}
        fake.nonce = q["nonce"]
        assert httpx.get(start["redirect_uri"].replace("/auth/callback", "/other")).status_code == 404
        r = httpx.get(f"{start['redirect_uri']}?code=c1&state={q['state']}&client_id={fake.client_id}")
        assert r.status_code == 200 and "接続しました" in r.text
        assert "href='http://100.64.0.1:8000/#/notes'" in r.text
        assert gpt.status()["connected"]
        # 済んだら待ち受けを止める
        time.sleep(0.5)
        assert not gpt.status()["listening"]
    finally:
        gpt.stop_listener()


def test_parse_output():
    out = "前置き\n<<<NOTE>>>\n# 10月11日\n\n> よい日\n<<<TODO>>>\n# やること\n- [ ] 何か\n<<<END>>>\n後書き"
    assert nightly.parse_chatgpt_output(out) == ("# 10月11日\n\n> よい日\n", "# やること\n- [ ] 何か\n")
    assert nightly.parse_chatgpt_output("<<<NOTE>>>\n```markdown\n# 題\n```\n<<<END>>>") == ("# 題\n", None)
    assert nightly.parse_chatgpt_output("まとめだけ") == (None, None)


def test_ai_run_from_the_web(tmp_path, fake):
    settings = Settings(data_dir=tmp_path / "data", api_tokens=[TOKEN], stt_engine="none", timezone="Asia/Tokyo")
    gpt = make_gpt(tmp_path, fake)
    app = create_app(settings, engine_factory=FakeEngine, diarizer_factory=FakeDiarizer, start_worker=False, chatgpt=gpt)
    client = TestClient(app)
    client.headers["Authorization"] = f"Bearer {TOKEN}"
    put_audio(client, "s1", make_ogg(tmp_path / "a.opus"))
    app.state.worker.drain()

    s = client.get("/api/v1/ai/status").json()
    assert not s["chatgpt"]["connected"] and s["job"]["state"] == "idle" and "2026-10-10" in s["days"]
    assert client.post("/api/v1/ai/run", json={"day": "2026-10-10"}).status_code == 401

    # Web 画面から接続する (この Mac 以外のブラウザなら、戻り先のアドレスを貼り付ける)
    start = client.post("/api/v1/ai/connect").json()
    q = {k: v[0] for k, v in parse_qs(urlsplit(start["authorize_url"]).query).items()}
    fake.nonce = q["nonce"]
    r = client.post("/api/v1/ai/callback", json={"url": f"{start['redirect_uri']}?code=c1&state={q['state']}&client_id=oaiapp_test123"})
    assert r.status_code == 200 and r.json()["connected"]
    assert client.post("/api/v1/ai/callback", json={"url": "http://127.0.0.1:1455/auth/callback?code=x&state=y"}).status_code == 400
    assert client.get("/api/v1/ai/models").json()["models"][0]["slug"] == "gpt-test"
    assert client.put("/api/v1/ai/model", json={"model": "gpt-test"}).json() == {"model": "gpt-test"}

    fake.stream_events = [
        {"type": "response.output_text.delta", "delta": "<<<NOTE>>>\n# 10月10日 (土)\n\n> テストの日\n"},
        {"type": "response.output_text.delta", "delta": "<<<TODO>>>\n# やること\n\n- [ ] 確かめる\n<<<END>>>"},
        {"type": "response.completed", "response": {}},
    ]
    job = client.post("/api/v1/ai/run", json={"day": "2026-10-10"}).json()
    assert job["state"] == "running" and job["day"] == "2026-10-10"
    app.state.ai._thread.join(10)
    s = client.get("/api/v1/ai/status").json()
    assert s["job"]["state"] == "done", s["job"]
    data = settings.data_dir
    assert (data / "notes/2026-10-10.md").read_text().startswith("# 10月10日 (土)")
    assert (data / "notes/todo.md").read_text() == "# やること\n\n- [ ] 確かめる\n"
    run = nightly.last_run(data)
    assert run["status"] == "ok" and run["agent"] == "chatgpt:gpt-test"
    body = fake.last_body
    assert body["model"] == "gpt-test" and body["store"] is False and body["stream"] is True
    assert "夜の整理: 10月10日 (土)" in body["instructions"] and "<<<NOTE>>>" in body["instructions"]
    text = body["input"][0]["content"][0]["text"]
    assert '<file path="timeline/2026-10-10.md">' in text and '<file path="AGENTS.md">' in text
    # まとめ・一覧にも出る
    assert client.get("/api/v1/notes").json()["notes"][0]["name"] == "2026-10-10.md"

    # 使用量の上限: 失敗として記録し、理由を出す
    fake.stream_events = [{"type": "response.failed", "response": {"error": {"code": "subscription_sharing_usage_limit_exceeded"}}}]
    client.post("/api/v1/ai/run", json={"day": "2026-10-10"})
    app.state.ai._thread.join(10)
    job = client.get("/api/v1/ai/status").json()["job"]
    assert job["state"] == "failed" and "使用量" in job["message"]
    assert client.post("/api/v1/ai/disconnect").json()["revoked"] is True
    assert not client.get("/api/v1/ai/status").json()["chatgpt"]["connected"]


def test_connect_from_iphone_does_not_listen(tmp_path, fake):
    settings = Settings(data_dir=tmp_path / "data", api_tokens=[TOKEN], stt_engine="none")
    gpt = ChatGPT(tmp_path / "data", transport=httpx.MockTransport(fake.handler))
    app = create_app(settings, start_worker=False, chatgpt=gpt)
    client = TestClient(app)
    client.headers["Authorization"] = f"Bearer {TOKEN}"
    start = client.post("/api/v1/ai/connect", json={"client": "iphone"}).json()
    try:
        # iPhone が自分の 127.0.0.1:1455 で受け取るので、サーバは待ち受けない
        assert start["redirect_uri"] == "http://127.0.0.1:1455/auth/callback"
        assert not gpt.status()["listening"] and gpt.status()["pending"]
        q = {k: v[0] for k, v in parse_qs(urlsplit(start["authorize_url"]).query).items()}
        fake.nonce = q["nonce"]
        r = client.post("/api/v1/ai/callback", json={"url": f"{start['redirect_uri']}?code=c1&state={q['state']}&client_id={fake.client_id}"})
        assert r.json()["connected"]
    finally:
        gpt.stop_listener()
