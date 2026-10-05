import AppKit
import Darwin
import Foundation
import Observation

@MainActor
@Observable
final class JobStore {
    static let supportDir = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/BlenderRenderMonitor")
    static let jobsDir = supportDir.appending(path: "jobs")
    static let hookURL = supportDir.appending(path: "render_monitor.py")
    static let keepExitedFor: TimeInterval = 12 * 3600

    private(set) var jobs: [RenderJob] = []
    private(set) var now = Date()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let logMonitor = LogMonitor()
    @ObservationIgnored private let queue = RenderQueue()
    @ObservationIgnored private let resources = ResourceMonitor()
    @ObservationIgnored private var quitIDs: Set<String> = []
    private(set) var maxConcurrent: Int?

    init() {
        installHook()
        maxConcurrent = queue.maxConcurrent
        refresh()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.queue.releaseQueued() }
        }
    }

    var activeJobs: [RenderJob] { jobs.filter { $0.state(now: now).isActive } }
    var renderingJobs: [RenderJob] { jobs.filter { $0.state(now: now) == .rendering } }

    func setMaxConcurrent(_ value: Int?) {
        queue.setMaxConcurrent(value)
        maxConcurrent = value
        refresh()
    }

    func togglePause(_ job: RenderJob) {
        queue.togglePause(id: job.id)
        refresh()
    }

    /// Asks Blender to quit (SIGTERM), or kills it outright (SIGKILL) when `force` is set.
    func quit(_ job: RenderJob, force: Bool) {
        quitIDs.insert(job.id)
        queue.release(id: job.id)
        kill(job.info.pid, force ? SIGKILL : SIGTERM)
        refresh()
    }

    func move(_ job: RenderJob, by offset: Int) {
        queue.move(id: job.id, by: offset)
        refresh()
    }

    func moveToTop(_ job: RenderJob) {
        queue.moveToTop(id: job.id)
        refresh()
    }

    func moveToBottom(_ job: RenderJob) {
        queue.moveToBottom(id: job.id)
        refresh()
    }

    var queueLength: Int { jobs.filter { $0.queuePosition != nil }.count }

    func job(id: String) -> RenderJob? { jobs.first { $0.id == id } }

    func refresh() {
        now = Date()
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Self.jobsDir, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        var hookJobs: [RenderJob] = files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let info = try? decoder.decode(JobStatus.self, from: data) else { return nil }
            return RenderJob(info: info, isAlive: Self.isBlenderRunning(pid: info.pid), statusFile: url)
        }
        hookJobs.removeAll { job in
            guard !job.isAlive, now.timeIntervalSince1970 - job.info.updatedAt > Self.keepExitedFor else { return false }
            if let file = job.statusFile { try? FileManager.default.removeItem(at: file) }
            return true
        }
        let hookPIDs = Set(hookJobs.filter(\.isAlive).map(\.info.pid))
        let found = (hookJobs + logMonitor.update(excluding: hookPIDs, now: now)).map { job -> RenderJob in
            var job = job
            job.isQuitting = quitIDs.contains(job.id)
            return job
        }
        let usage = resources.sample(pids: Set(found.filter(\.isAlive).map(\.info.pid)))
        let loaded = queue.apply(to: found, now: now).map { job -> RenderJob in
            var job = job
            job.usage = job.isAlive ? usage[job.info.pid] : nil
            return job
        }
        let sorted = loaded.sorted { a, b in
            switch (a.queuePosition, b.queuePosition) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.info.startedAt > b.info.startedAt
            }
        }
        if sorted != jobs { jobs = sorted }
    }

    /// Removes renders whose Blender process has exited.
    func clearFinished() {
        for job in jobs where !job.isAlive {
            if let file = job.statusFile { try? FileManager.default.removeItem(at: file) }
        }
        logMonitor.forgetExited()
        quitIDs.formIntersection(jobs.filter(\.isAlive).map(\.id))
        refresh()
    }

    func copyHookArgument() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("--python \"\(Self.hookURL.path)\"", forType: .string)
    }

    func revealHook() {
        NSWorkspace.shared.activateFileViewerSelecting([Self.hookURL])
    }

    /// Keeps a copy of the Blender hook at a stable path that render scripts can reference.
    private func installHook() {
        guard let bundled = Bundle.main.url(forResource: "render_monitor", withExtension: "py"),
              let contents = try? Data(contentsOf: bundled) else { return }
        try? FileManager.default.createDirectory(at: Self.jobsDir, withIntermediateDirectories: true)
        if (try? Data(contentsOf: Self.hookURL)) != contents {
            try? contents.write(to: Self.hookURL, options: .atomic)
        }
    }

    private static func isBlenderRunning(pid: Int32) -> Bool {
        guard kill(pid, 0) == 0 || errno == EPERM else { return false }
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return true }
        return String(cString: buffer).localizedCaseInsensitiveContains("blender")
    }
}
