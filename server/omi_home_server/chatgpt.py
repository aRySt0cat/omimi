"""Sign in with ChatGPT: 利用者の ChatGPT プランで AI (Responses API) を使う。

公式ドキュメント (https://developers.openai.com/siwc/token-sharing-open-source) の手順を実装する。
- 認可: https://auth.openai.com/api/accounts/authorize (PKCE S256。戻り先は 127.0.0.1 のループバック)
- トークン: https://auth.openai.com/api/accounts/oauth/token (authorization_code / refresh_token)
- 推論: https://api.openai.com/v1/responses (store=false, stream=true)

戻り先は自宅サーバ (この Mac) の 127.0.0.1 なので、この Mac のブラウザで許可すればそのまま完了する。
ほかの端末のブラウザで許可したときは、開けなかったページのアドレスを Web 画面に貼り付けて完了する。

トークンは <data>/chatgpt/auth.json (所有者だけ読める 0600) にだけ置き、ブラウザには渡さない。
"""

from __future__ import annotations

import base64
import fcntl
import hashlib
import html
import json
import logging
import os
import secrets
import threading
import time
import uuid
from contextlib import contextmanager
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Callable, Iterator
from urllib.parse import parse_qs, urlencode, urlsplit

import httpx

log = logging.getLogger(__name__)

AUTH_BASE = "https://auth.openai.com"
AUTHORIZE_URL = AUTH_BASE + "/api/accounts/authorize"
TOKEN_URL = AUTH_BASE + "/api/accounts/oauth/token"
OIDC_CONFIG_URL = AUTH_BASE + "/.well-known/openid-configuration"
API_BASE = "https://api.openai.com/v1"
RESOURCE = API_BASE
SCOPES = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
PLAN_SCOPE = "chatgpt.tokens.use.direct"
REGISTRATION_CLIENT = "dynamic_agent_client"
APP_NAME = "Omimi"
CALLBACK_PATH = "/auth/callback"
# 最初の登録は 1455 番で受ける (公式の例と同じ)。使えなければ次の番号 (変えてよいのは番号だけ)
CALLBACK_PORTS = (1455, 1456, 1457, 1458, 1459)
LOGIN_TIMEOUT = 10 * 60
REFRESH_MARGIN = 120
USAGE_URL = "https://chatgpt.com/settings/usage"


class ChatGPTError(Exception):
    """利用者に見せる文と、公式の error.code"""

    def __init__(self, message: str, code: str | None = None, status: int | None = None, reconnect: bool = False):
        super().__init__(message)
        self.message = message
        self.code = code
        self.status = status
        # 接続し直す必要がある (トークンが使えない)
        self.reconnect = reconnect


# 公式の「Errors and recovery」にあるコードと、そのときの案内
ERROR_MESSAGES = {
    "subscription_sharing_usage_limit_exceeded":
        "ChatGPT プランの使用量の上限に達しました。ChatGPT の設定 → 使用量 で確かめてください。",
    "subscription_sharing_user_not_eligible":
        "このアカウントでは ChatGPT プランを使えません (Plus または Pro が必要です)。",
    "subscription_sharing_usage_unavailable": "ChatGPT プランが一時的に使えません。少し待ってからもう一度試してください。",
    "subscription_sharing_user_unavailable": "ChatGPT プランが一時的に使えません。少し待ってからもう一度試してください。",
    "subscription_sharing_unsupported_capability": "選んだモデルか機能は ChatGPT プランでは使えません。別のモデルを選んでください。",
    "subscription_sharing_route_not_supported": "ChatGPT プランでは使えない呼び出しです。",
    "subscription_sharing_invalid_user": "ChatGPT の接続が使えなくなりました。もう一度「ChatGPT で続ける」から接続してください。",
}
# 接続し直さないと直らないもの (トークンの更新ができない・取り消された)
TERMINAL_REFRESH_ERRORS = {"invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired",
                           "refresh_token_invalidated", "refresh_token_reused"}


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def _b64url_decode(text: str) -> bytes:
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def decode_jwt(token: str) -> tuple[dict[str, Any], dict[str, Any], bytes, bytes]:
    """(ヘッダ, 中身, 署名する部分, 署名)。署名は確かめない。"""
    try:
        head_b64, body_b64, sig_b64 = token.split(".")
        header = json.loads(_b64url_decode(head_b64))
        payload = json.loads(_b64url_decode(body_b64))
        return header, payload, f"{head_b64}.{body_b64}".encode(), _b64url_decode(sig_b64)
    except (ValueError, TypeError) as e:
        raise ChatGPTError("ChatGPT から受け取った ID トークンを読めませんでした") from e


def verify_rs256(signing_input: bytes, signature: bytes, jwk: dict[str, Any]) -> bool:
    from cryptography.exceptions import InvalidSignature
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.asymmetric import padding
    from cryptography.hazmat.primitives.asymmetric.rsa import RSAPublicNumbers

    key = RSAPublicNumbers(int.from_bytes(_b64url_decode(jwk["e"]), "big"),
                           int.from_bytes(_b64url_decode(jwk["n"]), "big")).public_key()
    try:
        key.verify(signature, signing_input, padding.PKCS1v15(), hashes.SHA256())
        return True
    except InvalidSignature:
        return False


class ChatGPT:
    """接続 (Sign in with ChatGPT) とトークンの管理、Responses API の呼び出し。"""

    def __init__(self, data_dir: Path, *, transport: httpx.BaseTransport | None = None,
                 open_listener: bool = True, clock: Callable[[], float] = time.time):
        self.dir = data_dir / "chatgpt"
        self._transport = transport
        self._open_listener = open_listener
        self._clock = clock
        self._lock = threading.RLock()
        self._pending: dict[str, Any] | None = None
        self._listener: ThreadingHTTPServer | None = None
        self._oidc: dict[str, Any] | None = None
        self._jwks: dict[str, Any] | None = None
        self._models: tuple[float, list[dict[str, str]]] | None = None
        self.last_error: str | None = None

    # --- 保存 ---------------------------------------------------------------

    def _ensure_dir(self) -> None:
        self.dir.mkdir(parents=True, exist_ok=True)
        os.chmod(self.dir, 0o700)

    def _read(self, name: str) -> dict[str, Any]:
        try:
            return json.loads((self.dir / name).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return {}

    def _write(self, name: str, data: dict[str, Any]) -> None:
        """所有者だけ読めるファイルに、途中で壊れないよう置き換えで書く"""
        self._ensure_dir()
        path = self.dir / name
        tmp = path.with_suffix(".tmp")
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
        os.chmod(tmp, 0o600)
        tmp.replace(path)

    @contextmanager
    def _file_lock(self) -> Iterator[None]:
        """更新トークンは使うたびに変わるので、ほかのプロセス (夜の整理) と同時に更新しない"""
        self._ensure_dir()
        with self._lock, (self.dir / "auth.lock").open("w") as f:
            fcntl.flock(f, fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(f, fcntl.LOCK_UN)

    def host_id(self) -> str:
        """この自宅サーバ (エージェントのホスト) の ID。最初のサインインの前に決めて、ずっと同じものを使う"""
        host = self._read("host.json")
        if not host.get("ext_agent_host_id"):
            host = {"ext_agent_host_id": f"urn:uuid:{uuid.uuid4()}", "created_at": _now_iso()}
            self._write("host.json", host)
        return host["ext_agent_host_id"]

    def credentials(self) -> dict[str, Any]:
        return self._read("auth.json")

    # --- 状態 ---------------------------------------------------------------

    def status(self) -> dict[str, Any]:
        cred = self.credentials()
        scopes = cred.get("scopes") or []
        pending = self._pending if self._pending and self._clock() - self._pending["created"] < LOGIN_TIMEOUT else None
        return {
            "connected": bool(cred.get("access_token")),
            "plan_usage": PLAN_SCOPE in scopes,
            "email": cred.get("email"),
            "registered": bool(cred.get("client_id")),
            "pending": pending is not None,
            "redirect_uri": pending["redirect_uri"] if pending else None,
            "listening": bool(pending and self._listener),
            "welcome": bool(cred.get("access_token")) and not cred.get("welcomed"),
            "error": self.last_error,
            "usage_url": USAGE_URL,
        }

    def dismiss_welcome(self) -> None:
        with self._file_lock():
            cred = self.credentials()
            if cred:
                cred["welcomed"] = True
                self._write("auth.json", cred)

    # --- HTTP ---------------------------------------------------------------

    def _client(self, timeout: httpx.Timeout | float = 30.0) -> httpx.Client:
        return httpx.Client(transport=self._transport, timeout=timeout, follow_redirects=False,
                            headers={"User-Agent": f"{APP_NAME}/1 (omi-home-server)"})

    def _oidc_config(self) -> dict[str, Any]:
        if self._oidc is None:
            with self._client() as c:
                r = c.get(OIDC_CONFIG_URL)
                r.raise_for_status()
                self._oidc = r.json()
        return self._oidc

    def _jwk(self, kid: str | None) -> dict[str, Any]:
        for attempt in range(2):
            if self._jwks is None or attempt:
                with self._client() as c:
                    r = c.get(self._oidc_config()["jwks_uri"])
                    r.raise_for_status()
                    self._jwks = r.json()
            for key in self._jwks.get("keys", []):
                if kid is None or key.get("kid") == kid:
                    return key
        raise ChatGPTError("ChatGPT の ID トークンの署名を確かめられませんでした (鍵が見つかりません)")

    def verify_id_token(self, id_token: str, client_id: str, nonce: str | None) -> dict[str, Any]:
        """署名 (公開鍵)・発行元・宛先・期限・nonce を確かめる"""
        header, claims, signing_input, signature = decode_jwt(id_token)
        if header.get("alg") != "RS256":
            raise ChatGPTError("ChatGPT の ID トークンの形式が想定と違います")
        if not verify_rs256(signing_input, signature, self._jwk(header.get("kid"))):
            raise ChatGPTError("ChatGPT の ID トークンの署名が正しくありません")
        issuer = self._oidc_config().get("issuer", AUTH_BASE)
        audience = claims.get("aud")
        audiences = audience if isinstance(audience, list) else [audience]
        if claims.get("iss") != issuer or client_id not in audiences:
            raise ChatGPTError("ChatGPT の ID トークンの発行元か宛先が違います")
        if float(claims.get("exp", 0)) < self._clock() - 60:
            raise ChatGPTError("ChatGPT の ID トークンの期限が切れています")
        if nonce is not None and claims.get("nonce") != nonce:
            raise ChatGPTError("ChatGPT の ID トークンが今回のサインインのものではありません")
        if not claims.get("sub"):
            raise ChatGPTError("ChatGPT の ID トークンにアカウントの情報がありません")
        return claims

    # --- サインイン ---------------------------------------------------------

    def start_login(self, return_url: str | None = None, listen: bool = True) -> dict[str, Any]:
        """許可の画面の URL を作り、戻り先 (127.0.0.1) で待ち受けを始める。

        return_url: 許可のあとに見せる「Omimi に戻る」の行き先 (Web 画面のアドレス)
        listen: False なら待ち受けない (iPhone のアプリが自分の 127.0.0.1:1455 で受け取り、結果を送ってくる)
        """
        with self._lock:
            self.stop_listener()
            cred = self.credentials()
            issued = cred.get("client_id")
            verifier = _b64url(secrets.token_bytes(32))
            state, nonce = secrets.token_urlsafe(32), secrets.token_urlsafe(32)
            port = self._start_listener() if self._open_listener and listen else CALLBACK_PORTS[0]
            redirect_uri = f"http://127.0.0.1:{port}{CALLBACK_PATH}"
            params = {
                "client_id": issued or REGISTRATION_CLIENT,
                "ext_agent_host_id": self.host_id(),
                "response_type": "code",
                "redirect_uri": redirect_uri,
                "scope": SCOPES,
                "resource": RESOURCE,
                "state": state,
                "nonce": nonce,
                "code_challenge_method": "S256",
                "code_challenge": _b64url(hashlib.sha256(verifier.encode()).digest()),
            }
            if issued:
                # 2 回目からは、登録済みの client_id で同じアカウントにサインインし直す
                if cred.get("id_token"):
                    params["id_token_hint"] = cred["id_token"]
                if cred.get("email"):
                    params["login_hint"] = cred["email"]
            else:
                params["agent_name_hint"] = APP_NAME
            if return_url and not return_url.startswith(("http://", "https://")):
                return_url = None
            self._pending = {"state": state, "nonce": nonce, "verifier": verifier, "redirect_uri": redirect_uri,
                             "client_id": issued, "subject": cred.get("subject") if issued else None,
                             "return_url": return_url, "created": self._clock()}
            self.last_error = None
            return {"authorize_url": AUTHORIZE_URL + "?" + urlencode(params), "redirect_uri": redirect_uri}

    def complete_from_url(self, url: str) -> dict[str, Any]:
        """戻り先のアドレス (開けなかったページの URL) から、サインインを完了する"""
        parts = urlsplit(url.strip())
        query = {k: v[0] for k, v in parse_qs(parts.query).items()}
        if not query:
            raise ChatGPTError("貼り付けたアドレスに、許可の結果 (code や state) が入っていません")
        return self.complete(query)

    def complete(self, query: dict[str, str]) -> dict[str, Any]:
        """許可の結果を受け取り、トークンに換えて保存する"""
        with self._lock:
            pending = self._pending
            try:
                if not pending or self._clock() - pending["created"] > LOGIN_TIMEOUT:
                    raise ChatGPTError("サインインの受付が終わっています。もう一度「ChatGPT で続ける」を押してください")
                if not secrets.compare_digest(query.get("state", ""), pending["state"]):
                    raise ChatGPTError("今回のサインインの結果ではありません (state が違います)")
                if query.get("error"):
                    self._pending = None
                    if query["error"] == "access_denied":
                        raise ChatGPTError("ChatGPT での許可が取り消されました", code="access_denied")
                    raise ChatGPTError(f"ChatGPT でのサインインに失敗しました ({query['error']})", code=query["error"])
                code = query.get("code")
                if not code:
                    raise ChatGPTError("許可の結果に code がありません")
                returned = query.get("client_id")
                client_id = pending["client_id"]
                if client_id is None:
                    # はじめての登録: OpenAI が発行した client_id (oaiapp_...) を受け取る
                    if not returned or returned == REGISTRATION_CLIENT:
                        raise ChatGPTError("ChatGPT での登録が完了していません (client_id がありません)")
                    client_id = returned
                    # コードの交換に失敗しても登録をやり直さずに済むよう、先に保存する
                    with self._file_lock():
                        cred = self.credentials()
                        cred.update(client_id=client_id, ext_agent_host_id=self.host_id())
                        self._write("auth.json", cred)
                elif returned and returned != client_id:
                    raise ChatGPTError("登録済みのものと違う client_id が返ってきました")
                tokens = self._token_request({
                    "grant_type": "authorization_code", "client_id": client_id, "code": code,
                    "code_verifier": pending["verifier"], "redirect_uri": pending["redirect_uri"], "resource": RESOURCE,
                })
                claims = self.verify_id_token(tokens.get("id_token", ""), client_id, pending["nonce"])
                if pending.get("subject") and claims["sub"] != pending["subject"]:
                    raise ChatGPTError("前と違う ChatGPT アカウントでサインインしました。前のアカウントを使ってください")
                self._save_tokens(tokens, client_id=client_id, claims=claims)
                self._pending = None
                self.last_error = None
                return self.status()
            except ChatGPTError as e:
                self.last_error = e.message
                raise
            finally:
                if self._pending is None:
                    self.stop_listener(later=True)

    def _token_request(self, form: dict[str, str]) -> dict[str, Any]:
        with self._client() as c:
            r = c.post(TOKEN_URL, data=form, headers={"Accept": "application/json"})
        try:
            body = r.json()
        except ValueError:
            body = {}
        if r.status_code >= 400:
            code = body.get("error") if isinstance(body.get("error"), str) else (body.get("error") or {}).get("code")
            if code == "invalid_grant" and form["grant_type"] == "authorization_code":
                raise ChatGPTError("許可の結果が使えませんでした。もう一度「ChatGPT で続ける」を押してください", code=code,
                                   status=r.status_code)
            raise ChatGPTError(f"ChatGPT のトークンを受け取れませんでした ({code or r.status_code})", code=code,
                               status=r.status_code, reconnect=code in TERMINAL_REFRESH_ERRORS)
        return body

    def _save_tokens(self, tokens: dict[str, Any], *, client_id: str, claims: dict[str, Any] | None,
                     locked: bool = False) -> None:
        if not locked:
            with self._file_lock():
                self._save_tokens(tokens, client_id=client_id, claims=claims, locked=True)
            return
        cred = self.credentials()
        scope = tokens.get("scope")
        scopes = sorted(scope.split()) if isinstance(scope, str) else (tokens.get("scopes") or cred.get("scopes") or [])
        cred.update(
            client_id=client_id,
            ext_agent_host_id=self.host_id(),
            issuer=AUTH_BASE,
            access_token=tokens["access_token"],
            token_type=tokens.get("token_type", "Bearer"),
            expires_in=tokens.get("expires_in"),
            expires_at=self._clock() + float(tokens.get("expires_in") or 3600),
            scopes=scopes,
            saved_at=_now_iso(),
        )
        if tokens.get("refresh_token"):
            cred["refresh_token"] = tokens["refresh_token"]
        if tokens.get("id_token"):
            cred["id_token"] = tokens["id_token"]
        if claims is not None:
            cred.update(subject=claims["sub"], email=claims.get("email"))
        self._write("auth.json", cred)

    # --- 待ち受け (127.0.0.1) -----------------------------------------------

    def _start_listener(self) -> int:
        auth = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self) -> None:  # noqa: N802
                parts = urlsplit(self.path)
                if parts.path != CALLBACK_PATH:
                    self.send_error(404)
                    return
                query = {k: v[0] for k, v in parse_qs(parts.query).items()}
                back = (auth._pending or {}).get("return_url")
                try:
                    auth.complete(query)
                    title, text = "接続しました", "Omimi と ChatGPT をつなぎました。Omimi の画面に戻ってください。"
                except ChatGPTError as e:
                    title, text = "接続できませんでした", e.message + " Omimi の画面に戻って、もう一度試してください。"
                link = (f"<p><a href='{html.escape(back, quote=True)}' style='color:#2F5D9E'>Omimi に戻る</a></p>"
                        if back else "")
                page = (f"<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width'>"
                        f"<title>Omimi</title><body style='font:16px/1.7 system-ui,sans-serif;max-width:32em;"
                        f"margin:15vh auto;padding:0 24px;color:#1D2A44'><h1 style='font-size:22px'>{html.escape(title)}</h1>"
                        f"<p>{html.escape(text)}</p>{link}</body>").encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Cache-Control", "no-store")
                self.send_header("Referrer-Policy", "no-referrer")
                self.end_headers()
                self.wfile.write(page)

            def log_message(self, *args: Any) -> None:
                pass  # 許可の結果 (code) をログに残さない

        for port in CALLBACK_PORTS:
            try:
                server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
            except OSError:
                continue
            self._listener = server
            threading.Thread(target=server.serve_forever, name="chatgpt-callback", daemon=True).start()
            timer = threading.Timer(LOGIN_TIMEOUT, lambda s=server: self._stop(s))
            timer.daemon = True  # サーバの終了を待たせない
            timer.start()
            return port
        raise ChatGPTError("サインインの戻り先 (127.0.0.1:1455〜1459) が使えません。ほかのアプリのサインインを終えてから試してください")

    def _stop(self, server: ThreadingHTTPServer) -> None:
        if self._listener is server:
            self._listener = None
        server.shutdown()
        server.server_close()

    def stop_listener(self, later: bool = False) -> None:
        server = self._listener
        if server is None:
            return
        if later:
            # 応答を返し終えてから止める (待ち受けのスレッドの中から呼ばれるため)
            threading.Thread(target=self._stop, args=(server,), daemon=True).start()
        else:
            self._stop(server)

    # --- トークンの更新・接続の解除 -------------------------------------------

    def access_token(self) -> str:
        cred = self.credentials()
        if not cred.get("access_token"):
            raise ChatGPTError("ChatGPT とつながっていません。「ChatGPT で続ける」から接続してください", reconnect=True)
        if PLAN_SCOPE not in (cred.get("scopes") or []):
            raise ChatGPTError("ChatGPT プランの利用が許可されていません。もう一度「ChatGPT で続ける」から、プランの利用を許可してください",
                               reconnect=True)
        if float(cred.get("expires_at") or 0) - REFRESH_MARGIN > self._clock():
            return cred["access_token"]
        return self.refresh()

    def refresh(self) -> str:
        with self._file_lock():
            cred = self.credentials()
            # ほかのプロセスが先に更新していればそれを使う
            if float(cred.get("expires_at") or 0) - REFRESH_MARGIN > self._clock():
                return cred["access_token"]
            if not cred.get("refresh_token") or not cred.get("client_id"):
                raise ChatGPTError("ChatGPT の接続が切れています。「ChatGPT で続ける」から接続し直してください", reconnect=True)
            try:
                tokens = self._token_request({"grant_type": "refresh_token", "client_id": cred["client_id"],
                                              "refresh_token": cred["refresh_token"], "resource": RESOURCE})
            except ChatGPTError as e:
                if e.reconnect:
                    self._clear_tokens()
                    raise ChatGPTError("ChatGPT の接続が切れました。「ChatGPT で続ける」から接続し直してください",
                                       code=e.code, reconnect=True) from e
                raise
            claims = None
            if tokens.get("id_token"):
                claims = self.verify_id_token(tokens["id_token"], cred["client_id"], None)
                if cred.get("subject") and claims["sub"] != cred["subject"]:
                    raise ChatGPTError("ChatGPT のアカウントが変わりました。接続し直してください", reconnect=True)
            # 更新トークンは使うと変わるので、ロックを持ったまま新しいものを保存する
            self._save_tokens(tokens, client_id=cred["client_id"], claims=claims, locked=True)
            return tokens["access_token"]

    def _clear_tokens(self) -> None:
        cred = self.credentials()
        for key in ("access_token", "refresh_token", "id_token", "expires_at", "expires_in", "scopes", "welcomed"):
            cred.pop(key, None)
        # 登録 (client_id) とホスト ID は残し、次のサインインで使う
        self._write("auth.json", cred)

    def sign_out(self) -> bool:
        """更新トークンを取り消してから、手元のトークンを消す。取り消せたら True"""
        with self._file_lock():
            cred = self.credentials()
            revoked = True
            if cred.get("refresh_token") and cred.get("client_id"):
                try:
                    endpoint = self._oidc_config().get("revocation_endpoint")
                    if endpoint:
                        with self._client() as c:
                            r = c.post(endpoint, data={"token": cred["refresh_token"], "token_type_hint": "refresh_token",
                                                       "client_id": cred["client_id"]})
                        revoked = r.status_code == 200
                    else:
                        revoked = False
                except httpx.HTTPError:
                    revoked = False
            self._clear_tokens()
            self._models = None
            return revoked

    # --- Responses API ------------------------------------------------------

    @staticmethod
    def _error_from(status: int, body: Any, fallback: str) -> ChatGPTError:
        error = body.get("error") if isinstance(body, dict) else None
        code = error.get("code") if isinstance(error, dict) else None
        if code in ERROR_MESSAGES:
            message = ERROR_MESSAGES[code]
            if code == "subscription_sharing_unsupported_capability" and error.get("param"):
                message += f" ({error['param']})"
            return ChatGPTError(message, code=code, status=status, reconnect=code == "subscription_sharing_invalid_user")
        if status == 401:
            return ChatGPTError("ChatGPT が接続を受け付けませんでした。「ChatGPT で続ける」から接続し直してください",
                                code=code, status=status, reconnect=True)
        if status == 403:
            return ChatGPTError("ChatGPT プランでのこの呼び出しは許可されていません (地域などの制限)", code=code, status=status)
        if status in (429, 503):
            return ChatGPTError("ChatGPT が混み合っています。少し待ってからもう一度試してください", code=code, status=status)
        detail = (error or {}).get("message") if isinstance(error, dict) else (body.get("detail") if isinstance(body, dict) else None)
        return ChatGPTError(f"{fallback} ({code or status}{': ' + str(detail)[:200] if detail else ''})", code=code, status=status)

    def list_models(self, force: bool = False) -> list[dict[str, str]]:
        """この ChatGPT アカウントで選べるモデル (visibility が list のもの)"""
        if self._models and not force and self._clock() - self._models[0] < 600:
            return self._models[1]
        token = self.access_token()
        with self._client() as c:
            r = c.get(API_BASE + "/models", headers={"Authorization": f"Bearer {token}"})
        if r.status_code >= 400:
            raise self._error_from(r.status_code, r.json() if r.content else {}, "モデルの一覧を取れませんでした")
        body = r.json()
        items = body.get("models") or body.get("data") or []
        models = [{"slug": m.get("slug") or m.get("id"), "display_name": m.get("display_name") or m.get("slug") or m.get("id")}
                  for m in items if m.get("visibility", "list") == "list" and (m.get("slug") or m.get("id"))]
        self._models = (self._clock(), models)
        return models

    def respond(self, *, model: str, instructions: str, text: str,
                on_delta: Callable[[str], None] | None = None, timeout: float = 600) -> str:
        """Responses API を呼び、出力の文字列を返す。response.completed まで読んで初めて成功とする"""
        token = self.access_token()
        payload = {
            "model": model,
            "instructions": instructions,
            "input": [{"role": "user", "content": [{"type": "input_text", "text": text}]}],
            "store": False,
            "stream": True,
        }
        out: list[str] = []
        completed = False
        timeouts = httpx.Timeout(30.0, read=timeout)
        with self._client(timeouts) as c, c.stream("POST", API_BASE + "/responses", json=payload, headers={
                "Authorization": f"Bearer {token}", "Accept": "text/event-stream"}) as r:
            if r.status_code >= 400:
                raw = r.read()
                try:
                    body = json.loads(raw)
                except ValueError:
                    body = {"detail": raw.decode(errors="replace")[:300]}
                raise self._error_from(r.status_code, body, "AI に頼めませんでした")
            for line in r.iter_lines():
                if not line.startswith("data:"):
                    continue
                data = line[5:].strip()
                if not data or data == "[DONE]":
                    continue
                try:
                    event = json.loads(data)
                except ValueError:
                    continue
                kind = event.get("type")
                if kind == "response.output_text.delta":
                    delta = event.get("delta") or ""
                    out.append(delta)
                    if on_delta:
                        on_delta(delta)
                elif kind == "response.completed":
                    completed = True
                    break
                elif kind == "response.failed":
                    error = (event.get("response") or {}).get("error") or {}
                    raise self._error_from(200, {"error": error}, "AI の処理が失敗しました")
                elif kind == "response.incomplete":
                    reason = ((event.get("response") or {}).get("incomplete_details") or {}).get("reason")
                    raise ChatGPTError(f"AI の出力が途中で終わりました ({reason or 'incomplete'})", code="incomplete")
                elif kind == "error":
                    raise self._error_from(200, {"error": event.get("error") or event}, "AI の処理が失敗しました")
        if not completed:
            raise ChatGPTError("AI の応答が途中で切れました。もう一度試してください", code="interrupted")
        return "".join(out)
