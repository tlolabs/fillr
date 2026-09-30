import CFillr
import Foundation

// The Rust engine synchronizes snapshot and build access internally.
final class EngineBridge: @unchecked Sendable {
    private let handle: UnsafeMutableRawPointer

    init(folder: URL, policy: MediaPolicy) throws {
        guard fillr_api_version() == 1 else { throw BridgeError.message("Incompatible Rust engine") }
        let policyJSON = String(data: try JSONEncoder().encode(policy), encoding: .utf8)!
        let pointer = folder.path.withCString { folderCString in
            policyJSON.withCString { policyCString in
                fillr_create_configured_owned(folderCString, policyCString)
            }
        }
        guard let pointer else { throw BridgeError.message(Self.takeString(fillr_last_error())) }
        handle = pointer
    }

    deinit { fillr_destroy(handle) }

    func snapshot() throws -> EngineSnapshot {
        guard let raw = fillr_snapshot(handle) else { throw BridgeError.message(Self.takeString(fillr_last_error())) }
        return try JSONDecoder().decode(EngineSnapshot.self, from: Self.takeString(raw).data(using: .utf8)!)
    }

    func build() throws -> BuildResponse.Result {
        guard let raw = fillr_build(handle) else { throw BridgeError.message(Self.takeString(fillr_last_error())) }
        let response = try JSONDecoder().decode(BuildResponse.self, from: Self.takeString(raw).data(using: .utf8)!)
        guard response.ok, let result = response.result else { throw BridgeError.message(response.error ?? "Build failed") }
        return result
    }

    func refresh() { fillr_refresh(handle) }

    func setPolicy(_ policy: MediaPolicy) throws {
        let json = String(data: try JSONEncoder().encode(policy), encoding: .utf8)!
        let accepted = json.withCString { fillr_set_media_policy(handle, $0) }
        guard accepted == 1 else { throw BridgeError.message(Self.takeString(fillr_last_error())) }
    }

    private static func takeString(_ value: UnsafeMutablePointer<CChar>?) -> String {
        guard let value else { return "Unknown engine error" }
        let text = String(cString: value)
        fillr_free_string(value)
        return text
    }
}

enum BridgeError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let message) = self { return message }
        return nil
    }
}
