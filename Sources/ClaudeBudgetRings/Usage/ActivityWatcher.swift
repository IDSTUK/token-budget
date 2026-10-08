import CoreServices
import Foundation

/// Watches Claude Code's transcript tree for writes.
///
/// Utilisation can only move when requests are being made, and every request
/// Claude Code makes appends to a transcript under `~/.claude/projects`
/// (including `<session>/subagents/*.jsonl`, hence the recursive stream). If
/// nothing has been written since the last poll, the poll is skipped.
///
/// This only sees Claude Code. Usage from claude.ai in a browser or the
/// desktop chat also counts against the windows but leaves nothing here, so
/// the poller still makes an occasional heartbeat fetch while idle.
final class ActivityWatcher {
    private(set) var lastActivity: Date?
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "claude-budget-rings.activity")
    private let lock = NSLock()
    private let onActivity: @Sendable () -> Void

    static var projectsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    init(onActivity: @escaping @Sendable () -> Void) {
        self.onActivity = onActivity
    }

    var lastActivityDate: Date? {
        lock.lock(); defer { lock.unlock() }
        return lastActivity
    }

    func start() {
        guard stream == nil else { return }
        let path = Self.projectsDirectory.path
        guard FileManager.default.fileExists(atPath: path) else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<ActivityWatcher>.fromOpaque(info).takeUnretainedValue()
            let array = unsafeBitCast(paths, to: NSArray.self)
            var sawTranscript = false
            for i in 0..<count {
                if let p = array[i] as? String, p.hasSuffix(".jsonl") { sawTranscript = true; break }
            }
            if sawTranscript { watcher.noteActivity() }
        }
        stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            2.0, // coalesce: a streaming turn writes many times a second
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        )
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func noteActivity() {
        lock.lock()
        lastActivity = Date()
        lock.unlock()
        onActivity()
    }

    deinit { stop() }
}
