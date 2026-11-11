import Foundation

/// The launcher's commit row: the same /api/git his /git page uses, on the dev server on this
/// Mac. The route only exists on a dev server, so this always goes to localhost, whichever site
/// the panel shows.
enum DevGit {
    /// The `URL` default's origin when that's a dev server here, otherwise localhost:3000.
    private static var api: URL {
        let fallback = URL(string: "http://localhost:3000/api/git")!
        let page = Page.notes.url
        guard let host = page.host?.lowercased(),
              ["localhost", "127.0.0.1", "::1"].contains(host) || host.hasSuffix(".localhost"),
              var parts = URLComponents(url: page, resolvingAgainstBaseURL: true)
        else { return fallback }
        parts.path = "/api/git"
        parts.query = nil
        parts.fragment = nil
        return parts.url ?? fallback
    }

    /// Committing, pulling and pushing can take half a minute, more on a slow network, and the
    /// first request after the dev server starts waits for the route to compile.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 300
        return URLSession(configuration: configuration)
    }()

    typealias Done = (Result<[String: Any], LauncherError>) -> Void

    /// `{changed, ahead, branch}`, answered on the main thread.
    static func status(password: String, done: @escaping Done) {
        call(password, nil) { result in
            finish(result.map(state), done)
        }
    }

    /// As /git's one button does: commit (everything, if nothing is staged), pull, push, each
    /// only if the one before worked. Answers with the status after the push.
    static func commit(password: String, message: String, done: @escaping Done) {
        call(password, ["action": "commit", "message": message]) { committed in
            guard case .success = committed else { return finish(committed, done) }
            call(password, ["action": "pull"]) { pulled in
                guard case .success = pulled else { return finish(pulled, done) }
                call(password, ["action": "push"]) { pushed in
                    finish(pushed.map(state), done)
                }
            }
        }
    }

    private static func finish(_ result: Result<[String: Any], LauncherError>, _ done: @escaping Done) {
        DispatchQueue.main.async { done(result) }
    }

    /// What the launcher shows from /git's status: how many files changed, staged or not, and
    /// how many commits are waiting to be pushed.
    private static func state(_ status: [String: Any]) -> [String: Any] {
        let staged = (status["staged"] as? [Any])?.count ?? 0
        let unstaged = (status["unstaged"] as? [Any])?.count ?? 0
        return [
            "changed": staged + unstaged,
            "ahead": status["ahead"] as? Int ?? 0,
            // Null on a detached HEAD, which git itself calls HEAD.
            "branch": status["branch"] as? String ?? "HEAD",
        ]
    }

    /// One request: a GET for the status, or a POST of `body`. Every answer from the route is
    /// the status after it, or `{error}`.
    private static func call(_ password: String, _ body: [String: Any]?, done: @escaping Done) {
        var request = URLRequest(url: api)
        request.setValue(password, forHTTPHeaderField: "x-read2-password")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        session.dataTask(with: request) { data, response, error in
            if let error {
                let code = (error as? URLError)?.code
                if code == .cannotConnectToHost || code == .cannotFindHost {
                    return done(.failure(LauncherError("dev server isn't running")))
                }
                if code == .timedOut {
                    return done(.failure(LauncherError("the dev server didn't answer in time")))
                }
                return done(.failure(LauncherError(error.localizedDescription)))
            }
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let message = json?["error"] as? String {
                return done(.failure(LauncherError(message)))
            }
            guard (200..<300).contains(status), let json else {
                return done(.failure(LauncherError("the dev server answered \(status)")))
            }
            done(.success(json))
        }.resume()
    }
}
