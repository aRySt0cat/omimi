import AuthenticationServices
import OmiKit
import UIKit

/// ChatGPT の許可の画面 (ASWebAuthenticationSession) を出す。
/// 許可のあとブラウザは http://127.0.0.1:1455/auth/callback に戻るので、それを LoopbackCallback で受け取る。
@MainActor
final class ChatGPTSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    /// 許可の画面を出し、戻ってきたアドレスを返す
    func authorize(url: URL, link: LoopbackCallback) async throws -> URL {
        // この画面は ChatGPT のサイトから omimi:// には戻らない。戻りは 127.0.0.1 で受け取り、こちらから閉じる
        let session = ASWebAuthenticationSession(url: url, callback: .customScheme("omimi")) { _, error in
            if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                link.cancel()  // 利用者が閉じた
            }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false  // Safari で ChatGPT にログイン済みならそれを使う
        self.session = session
        guard session.start() else {
            link.cancel()
            throw LoopbackError.cannotListen("許可の画面を開けませんでした")
        }
        defer {
            session.cancel()
            self.session = nil
        }
        return try await link.waitForCallback()
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows).first { $0.isKeyWindow } ?? ASPresentationAnchor()
        }
    }
}
