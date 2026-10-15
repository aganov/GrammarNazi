import Foundation

private final class CancellationProbe {
    let check: () -> Bool
    init(_ check: @escaping () -> Bool) { self.check = check }
}

/// Access only from the serial inference queue, including destruction.
final class EmbeddedInferenceSession: InferenceSession {
    private let handle: OpaquePointer

    init() throws {
        guard let handle = gn_session_create() else { throw EditingFailure("Could not initialize local inference.") }
        self.handle = handle
    }

    deinit { gn_session_destroy(handle) }
    var modelLoadCount: Int { Int(gn_session_load_count(handle)) }

    func run(model: URL, request: Data, isCancelled: @escaping () -> Bool) throws -> Data {
        guard let json = String(data: request, encoding: .utf8), !json.contains("\0") else {
            throw EditingFailure("Invalid inference request.")
        }
        let probe = CancellationProbe(isCancelled)
        var output: UnsafeMutablePointer<CChar>?
        var error: UnsafeMutablePointer<CChar>?
        let status = withExtendedLifetime(probe) {
            gn_session_run(handle, model.path, json, { pointer in
                guard let pointer else { return true }
                return Unmanaged<CancellationProbe>.fromOpaque(pointer).takeUnretainedValue().check()
            }, Unmanaged.passUnretained(probe).toOpaque(), &output, &error)
        }
        defer { gn_string_free(output); gn_string_free(error) }
        if status == 2 { throw CancellationError() }
        guard status == 0, let output else {
            throw EditingFailure(error.map { String(cString: $0) } ?? "Local inference failed.")
        }
        return Data(bytes: output, count: strlen(output))
    }
}
