import Darwin
import Foundation

/// Orders active renders, keeps at most `maxConcurrent` of them running, and pauses the rest
/// by stopping their Blender process (SIGSTOP), which resumes exactly where it left off (SIGCONT).
@MainActor
final class RenderQueue {
    struct State: Codable {
        var order: [String] = []
        /// nil runs every render at once.
        var maxConcurrent: Int?
        var manuallyPaused: Set<String> = []
        /// Renders whose process this app stopped, by job id.
        var stoppedByApp: [String: Int32] = [:]
        var pauses: [String: [RenderJob.PauseInterval]] = [:]
    }

    private static let file = JobStore.supportDir.appending(path: "queue.json")
    private(set) var state: State

    init() {
        state = (try? Data(contentsOf: Self.file)).flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
    }

    var maxConcurrent: Int? { state.maxConcurrent }

    func setMaxConcurrent(_ value: Int?) {
        state.maxConcurrent = value
        save()
    }

    func togglePause(id: String) {
        if state.manuallyPaused.contains(id) {
            state.manuallyPaused.remove(id)
        } else {
            state.manuallyPaused.insert(id)
        }
        save()
    }

    func move(id: String, by offset: Int) {
        guard let from = state.order.firstIndex(of: id) else { return }
        let to = min(max(0, from + offset), state.order.count - 1)
        state.order.remove(at: from)
        state.order.insert(id, at: to)
        save()
    }

    func moveToTop(id: String) { move(id: id, by: -state.order.count) }
    func moveToBottom(id: String) { move(id: id, by: state.order.count) }

    /// Starts or stops processes to match the queue, and annotates jobs with their hold, pauses and schedule.
    func apply(to jobs: [RenderJob], now: Date) -> [RenderJob] {
        let t = now.timeIntervalSince1970
        let queueable = jobs.filter { job in
            job.isAlive && (state.stoppedByApp[job.id] != nil || job.state(now: now) == .rendering)
        }
        let ids = Set(queueable.map(\.id))
        state.order.removeAll { !ids.contains($0) }
        for job in queueable.sorted(by: { $0.info.startedAt < $1.info.startedAt }) where !state.order.contains(job.id) {
            state.order.append(job.id)
        }
        let present = Set(jobs.map(\.id))
        state.manuallyPaused.formIntersection(ids)
        state.stoppedByApp = state.stoppedByApp.filter { ids.contains($0.key) }
        state.pauses = state.pauses.filter { present.contains($0.key) }

        let byID = Dictionary(uniqueKeysWithValues: queueable.map { ($0.id, $0) })
        var holds: [String: RenderJob.Hold] = [:]
        var running = 0
        for id in state.order {
            guard let job = byID[id] else { continue }
            if state.manuallyPaused.contains(id) {
                holds[id] = .paused
                stop(job, at: t)
            } else if let limit = state.maxConcurrent, running >= limit {
                holds[id] = .queued
                stop(job, at: t)
            } else {
                running += 1
                resume(job, at: t)
            }
        }
        save()

        var annotated = jobs.map { job -> RenderJob in
            var job = job
            job.hold = holds[job.id]
            job.pauses = state.pauses[job.id] ?? []
            job.queuePosition = state.order.firstIndex(of: job.id).map { $0 + 1 }
            return job
        }
        schedule(&annotated, now: now)
        return annotated
    }

    /// Resumes renders that are only waiting in the queue, so none stay frozen after the app quits.
    func releaseQueued() {
        let t = Date().timeIntervalSince1970
        for (id, pid) in state.stoppedByApp where !state.manuallyPaused.contains(id) {
            kill(pid, SIGCONT)
            state.stoppedByApp[id] = nil
            closePause(id, at: t)
        }
        save()
    }

    /// Estimates when each render starts and finishes, filling `maxConcurrent` slots in queue order.
    private func schedule(_ jobs: inout [RenderJob], now: Date) {
        let index = Dictionary(uniqueKeysWithValues: jobs.enumerated().map { ($1.id, $0) })
        let waiting = state.order.compactMap { index[$0] }.filter { jobs[$0].hold != .paused }
        var slots = [Double](repeating: 0, count: max(1, state.maxConcurrent ?? waiting.count))
        for i in waiting {
            let slot = slots.indices.min { slots[$0] < slots[$1] }!
            guard slots[slot].isFinite, let remaining = jobs[i].secondsRemaining(now: now) else {
                slots[slot] = .infinity
                continue
            }
            jobs[i].expectedStart = now.addingTimeInterval(slots[slot])
            slots[slot] += remaining
            jobs[i].expectedFinish = now.addingTimeInterval(slots[slot])
        }
    }

    private func stop(_ job: RenderJob, at t: Double) {
        guard state.stoppedByApp[job.id] == nil else { return }
        guard kill(job.info.pid, SIGSTOP) == 0 else { return }
        state.stoppedByApp[job.id] = job.info.pid
        state.pauses[job.id, default: []].append(.init(start: t, end: nil))
    }

    private func resume(_ job: RenderJob, at t: Double) {
        guard state.stoppedByApp[job.id] != nil else { return }
        kill(job.info.pid, SIGCONT)
        state.stoppedByApp[job.id] = nil
        closePause(job.id, at: t)
    }

    private func closePause(_ id: String, at t: Double) {
        guard var list = state.pauses[id], let last = list.indices.last, list[last].end == nil else { return }
        list[last].end = t
        state.pauses[id] = list
    }

    private var savedData: Data?

    private func save() {
        guard let data = try? JSONEncoder().encode(state), data != savedData else { return }
        try? data.write(to: Self.file, options: .atomic)
        savedData = data
    }
}
