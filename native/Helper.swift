import Foundation
import Darwin

struct Failure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

// The signal handler and parent watchdog can stop the child while HTTP is waiting.
final class ChildOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var child: Process?
    private var temporary: URL?
    func set(_ process: Process) { lock.lock(); child = process; lock.unlock() }
    func setTemporary(_ url: URL) { lock.lock(); temporary = url; lock.unlock() }
    func stop() {
        lock.lock()
        defer { lock.unlock() }
        let process = child; let directory = temporary; child = nil; temporary = nil
        if let process, process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }
}

let owner = ChildOwner()
let parent = getppid()
let signalQueue = DispatchQueue(label: "grammarly.cleanup")
var signalSources: [DispatchSourceSignal] = []
for number in [SIGTERM, SIGINT, SIGHUP] {
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: signalQueue)
    source.setEventHandler { owner.stop(); exit(128 + number) }
    source.resume()
    signalSources.append(source)
}
let watchdog = DispatchSource.makeTimerSource(queue: signalQueue)
watchdog.schedule(deadline: .now() + 1, repeating: 1)
watchdog.setEventHandler { if getppid() != parent { owner.stop(); exit(1) } }
watchdog.resume()

func availablePort() throws -> UInt16 {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw Failure("Cannot create a local socket.") }
    defer { close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let status = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard status == 0 else { throw Failure("Cannot bind a local socket.") }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
    }
    guard named == 0 else { throw Failure("Cannot choose a local port.") }
    return UInt16(bigEndian: address.sin_port)
}

final class HTTPResult: @unchecked Sendable {
    var value: Result<(Data, HTTPURLResponse), Error>?
}

func request(_ session: URLSession, _ url: URL, token: String, body: Data? = nil, timeout: Double) throws -> (Data, HTTPURLResponse) {
    var request = URLRequest(url: url, timeoutInterval: timeout)
    request.httpMethod = body == nil ? "GET" : "POST"
    request.httpBody = body
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    let semaphore = DispatchSemaphore(value: 0)
    let result = HTTPResult()
    let task = session.dataTask(with: request) { data, response, error in
        if let error { result.value = .failure(error) }
        else if let data, let response = response as? HTTPURLResponse { result.value = .success((data, response)) }
        else { result.value = .failure(Failure("Invalid local HTTP response.")) }
        semaphore.signal()
    }
    task.resume()
    guard semaphore.wait(timeout: .now() + timeout + 1) == .success else {
        task.cancel()
        throw Failure("Local inference timed out. Try a shorter passage.")
    }
    return try result.value!.get()
}

func run() throws {
    guard CommandLine.arguments.count == 4 else { throw Failure("Usage: grammarly-helper SERVER MODEL REQUEST_FILE") }
    let args = CommandLine.arguments
    guard FileManager.default.isExecutableFile(atPath: args[1]) else { throw Failure("llama-server is missing or not executable. Run npm run setup and rebuild.") }
    guard FileManager.default.fileExists(atPath: args[2]) else { throw Failure("The GGUF model is missing. Check the Models Folder preference.") }
    let body = try Data(contentsOf: URL(fileURLWithPath: args[3]))
    guard body.count <= 256_000, (try JSONSerialization.jsonObject(with: body)) is [String: Any] else { throw Failure("Invalid inference request.") }
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("grammarly-helper-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    owner.setTemporary(temporary)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let key = UUID().uuidString + UUID().uuidString
    let keyFile = temporary.appendingPathComponent("key")
    try Data(key.utf8).write(to: keyFile)
    let logFile = temporary.appendingPathComponent("runtime.log")
    FileManager.default.createFile(atPath: logFile.path, contents: nil, attributes: [.posixPermissions: 0o600])
    let log = try FileHandle(forWritingTo: logFile)
    defer { try? log.close() }
    let port = try availablePort()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: args[1])
    process.currentDirectoryURL = process.executableURL!.deletingLastPathComponent()
    process.arguments = ["--model", args[2], "--host", "127.0.0.1", "--port", String(port), "--api-key-file", keyFile.path,
                         "--ctx-size", "16384", "--parallel", "1", "--n-gpu-layers", "99",
                         "--no-webui", "--no-slots", "--log-disable", "--jinja", "--chat-template-kwargs", "{\"enable_thinking\":false}"]
    // No inherited llama.cpp options can enable extra endpoints or change the selected model.
    process.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = log
    process.standardError = log
    owner.set(process)
    try process.run()
    defer { owner.stop() }
    let config = URLSessionConfiguration.ephemeral
    config.connectionProxyDictionary = [:]
    config.urlCache = nil
    config.httpCookieStorage = nil
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    let base = URL(string: "http://127.0.0.1:\(port)")!
    let deadline = Date().addingTimeInterval(90)
    var ready = false
    while Date() < deadline && process.isRunning {
        if let (_, response) = try? request(session, base.appendingPathComponent("health"), token: key, timeout: 1), response.statusCode == 200 {
            ready = true; break
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
    guard ready else { throw Failure("llama.cpp could not load the model. Check available memory, the GGUF file and runtime version.") }
    let (data, response) = try request(session, base.appendingPathComponent("v1/chat/completions"), token: key, body: body, timeout: 120)
    guard response.statusCode == 200 else {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let message = (json?["error"] as? [String: Any])?["message"] as? String
        throw Failure(message.map { String($0.prefix(400)) } ?? "Local model returned HTTP \(response.statusCode).")
    }
    guard data.count <= 2 * 1024 * 1024 else { throw Failure("Local model response is too large.") }
    // Stop and reap the server before reporting success so models never overlap.
    owner.stop()
    FileHandle.standardOutput.write(data)
}

do { try run() }
catch {
    owner.stop()
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
