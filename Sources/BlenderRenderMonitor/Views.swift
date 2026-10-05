import SwiftUI

enum Brand {
    static let orange = Color(red: 0.96, green: 0.47, blue: 0.16)
    static let amber = Color(red: 1.0, green: 0.73, blue: 0.22)
    static let navy = Color(red: 0.09, green: 0.09, blue: 0.25)
    static let indigo = Color(red: 0.16, green: 0.13, blue: 0.42)
    static let fire = LinearGradient(colors: [orange, amber], startPoint: .leading, endPoint: .trailing)
    static let night = LinearGradient(colors: [navy, indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
}

struct ContentView: View {
    let store: JobStore

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(store: store)
            if store.jobs.isEmpty {
                EmptyStateView(store: store)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(store.jobs) { job in
                            JobRow(store: store, job: job)
                        }
                    }
                    .padding(14)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 260)
        .tint(Brand.orange)
        .toolbar {
            ToolbarItemGroup {
                Picker("Run", selection: Binding(get: { store.maxConcurrent }, set: { store.setMaxConcurrent($0) })) {
                    Text("All at once").tag(Int?.none)
                    Text("One at a time").tag(Int?.some(1))
                    Text("Two at a time").tag(Int?.some(2))
                    Text("Three at a time").tag(Int?.some(3))
                }
                .pickerStyle(.menu)
                .help("How many renders run at once. The rest wait, paused, in queue order.")
                Menu {
                    Button("Copy --python Argument") { store.copyHookArgument() }
                    Button("Show Hook Script in Finder") { store.revealHook() }
                } label: {
                    Label("Blender Hook", systemImage: "puzzlepiece.extension")
                }
                Button {
                    store.clearFinished()
                } label: {
                    Label("Clear Finished", systemImage: "trash")
                }
                .help("Remove renders whose Blender process has exited")
                .disabled(!store.jobs.contains { !$0.isAlive })
            }
        }
    }
}

struct JobRow: View {
    let store: JobStore
    let job: RenderJob
    @State private var showDetail = false
    @State private var isHovered = false
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        let now = store.now
        let state = job.state(now: now)
        let canControl = job.queuePosition != nil
        HStack(alignment: .center, spacing: 14) {
            if canControl {
                Button { store.togglePause(job) } label: {
                    StateIcon(state: state, showsControl: isHovered)
                }
                .buttonStyle(.plain)
                .help(state == .paused ? "Resume" : "Pause")
            } else {
                StateIcon(state: state, showsControl: false)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    if let position = job.queuePosition, store.queueLength > 1 {
                        Text("#\(position)")
                            .font(.system(.caption, design: .rounded).weight(.bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(position == 1 ? AnyShapeStyle(Brand.fire) : AnyShapeStyle(Brand.indigo)))
                    }
                    Text(job.title).font(.system(.headline, design: .rounded)).lineLimit(1)
                        .layoutPriority(1)
                    Text(job.outputName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .truncationMode(.head)
                }
                RenderProgressBar(value: state == .finished ? 1 : job.progress, active: state == .rendering)
                HStack {
                    Text(frameText)
                    if job.sampleFraction != nil, let s = job.info.sample, let n = job.info.samples {
                        Text(verbatim: "· sample \(s)/\(n)")
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            VStack(alignment: .trailing, spacing: 2) {
                if state == .rendering {
                    Text(Format.duration(job.secondsRemaining(now: now)))
                        .font(.system(.title2, design: .rounded).weight(.semibold).monospacedDigit())
                        .foregroundStyle(Brand.fire)
                    Text("remaining").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(state.label)
                        .font(.system(.callout, design: .rounded).weight(.medium))
                        .foregroundStyle(state.color)
                    if state == .queued, let start = job.expectedStart {
                        Text("starts \(Format.clock(start, relativeTo: now))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    } else if state == .paused, let remaining = job.secondsRemaining(now: now) {
                        Text("\(Format.duration(remaining)) left")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(minWidth: 90, alignment: .trailing)
            if canControl && store.queueLength > 1 {
                VStack(spacing: 2) {
                    Button { store.move(job, by: -1) } label: { Image(systemName: "chevron.up") }
                        .help("Higher priority")
                        .disabled(job.queuePosition == 1)
                    Button { store.move(job, by: 1) } label: { Image(systemName: "chevron.down") }
                        .help("Lower priority")
                        .disabled(job.queuePosition == store.queueLength)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11, weight: .bold))
                .opacity(isHovered ? 1 : 0)
            }
        }
        .contextMenu {
            if canControl {
                Button(state == .paused ? "Resume" : "Pause") { store.togglePause(job) }
                Divider()
                Button("Move to Top") { store.moveToTop(job) }
                Button("Move Up") { store.move(job, by: -1) }
                Button("Move Down") { store.move(job, by: 1) }
                Button("Move to Bottom") { store.moveToBottom(job) }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(isHovered ? 0.12 : 0.05), radius: isHovered ? 8 : 3, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isHovered ? Brand.orange.opacity(0.5) : Color.primary.opacity(0.06), lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
            hoverTask?.cancel()
            if hovering {
                hoverTask = Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    if !Task.isCancelled { showDetail = true }
                }
            } else {
                showDetail = false
            }
        }
        .popover(isPresented: $showDetail, arrowEdge: .trailing) {
            JobDetail(store: store, jobID: job.id)
        }
    }

    private var frameText: String {
        let frame = job.isMidFrame ? job.info.currentFrame : (job.info.lastCompletedFrame ?? job.info.currentFrame)
        guard job.hasRange else { return "Frame \(frame)" }
        return "Frame \(frame) of \(job.info.frameStart)–\(job.info.frameEnd)"
    }
}

struct JobDetail: View {
    let store: JobStore
    let jobID: String

    var body: some View {
        if let job = store.job(id: jobID) {
            let now = store.now
            let remaining = job.secondsRemaining(now: now)
            let state = job.state(now: now)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(job.title).font(.system(.headline, design: .rounded))
                    Spacer()
                    Text(state == .rendering ? Format.duration(remaining) + " left" : state.label)
                        .font(.system(.headline, design: .rounded).monospacedDigit())
                        .foregroundStyle(state == .rendering ? AnyShapeStyle(Brand.fire) : AnyShapeStyle(state.color))
                }
                .gridCellColumns(2)
                RenderProgressBar(value: job.progress, active: state == .rendering)
                    .gridCellColumns(2)
                    .padding(.bottom, 4)
                row("Time per frame", Format.duration(job.averageFrameSeconds)
                    + (job.info.frameTimes.count > 1 ? "  (avg of last \(min(10, job.info.frameTimes.count)))" : ""))
                row("Last frame", Format.duration(job.lastFrameSeconds))
                if let elapsed = job.currentFrameElapsed(now: now) {
                    row("Current", currentFrameText(job, elapsed: elapsed))
                }
                if let left = job.framesLeft, let total = job.totalFrames {
                    row("Frames left", "\(left) of \(total)")
                } else {
                    row("Frames left", "unknown (reading frame range…)")
                }
                row("Time left", Format.duration(remaining) + (state == .rendering ? "" : " of rendering"))
                if let position = job.queuePosition, store.queueLength > 1 {
                    row("Queue", "#\(position) of \(store.queueLength)")
                }
                if state == .queued, let start = job.expectedStart {
                    row("Starts", Format.clock(start, relativeTo: now))
                }
                if let finish = job.expectedFinish, state != .paused {
                    row("Finishes", Format.clock(finish, relativeTo: now))
                }
                Divider().gridCellColumns(2)
                row("Rendered", "\(job.info.framesRendered) frame\(job.info.framesRendered == 1 ? "" : "s") this session")
                row("Running for", Format.duration(now.timeIntervalSince1970 - job.info.startedAt))
                if !job.info.engine.isEmpty {
                    row("Engine", engineText(job))
                }
                row("Output", job.info.outputPath)
                if let log = job.info.logPath {
                    row("Source", "Blender log \((log as NSString).lastPathComponent)")
                }
                row("Process", "PID \(job.info.pid)" + (job.isAlive ? "" : " (exited)")
                    + (job.info.background == true ? ", headless" : ""))
            }
            .font(.callout.monospacedDigit())
            .padding(14)
            .frame(width: 380)
        } else {
            Text("This render is gone.").padding()
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
        }
    }

    private func currentFrameText(_ job: RenderJob, elapsed: Double) -> String {
        var text = "frame \(job.info.currentFrame), \(Format.duration(elapsed)) so far"
        if job.sampleFraction != nil, let s = job.info.sample, let n = job.info.samples {
            text += ", sample \(s)/\(n)"
        }
        return text
    }

    private func engineText(_ job: RenderJob) -> String {
        let engine = job.info.engine.replacingOccurrences(of: "BLENDER_", with: "").capitalized
        guard let res = job.info.resolution, res.count == 2 else { return engine }
        return "\(engine), \(res[0])×\(res[1])"
    }
}

struct StateIcon: View {
    let state: RenderJob.State
    /// Shows the pause/resume action instead of the state, for hover.
    let showsControl: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(state.color.opacity(showsControl ? 0.3 : 0.15))
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(state == .rendering ? AnyShapeStyle(Brand.fire) : AnyShapeStyle(state.color))
                .symbolEffect(.pulse, isActive: state == .rendering && !showsControl)
        }
        .frame(width: 38, height: 38)
        .contentShape(Circle())
    }

    private var symbol: String {
        if showsControl { return state == .paused ? "play.fill" : "pause.fill" }
        switch state {
        case .rendering: return "play.fill"
        case .queued: return "hourglass"
        case .paused: return "pause.fill"
        case .idle: return "moon.zzz.fill"
        case .finished: return "checkmark"
        case .cancelled: return "xmark"
        case .stopped: return "exclamationmark"
        }
    }
}

extension RenderJob.State {
    var color: Color {
        switch self {
        case .rendering: Brand.orange
        case .queued: Brand.indigo
        case .paused: .yellow
        case .finished: .green
        case .stopped: .red
        case .idle, .cancelled: .secondary
        }
    }
}

struct RenderProgressBar: View {
    let value: Double
    let active: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(active ? AnyShapeStyle(Brand.fire) : AnyShapeStyle(Color.secondary.opacity(0.5)))
                    .frame(width: max(6, geo.size.width * value))
                    .shadow(color: active ? Brand.orange.opacity(0.6) : .clear, radius: 4)
            }
        }
        .frame(height: 6)
    }
}

struct HeaderView: View {
    let store: JobStore

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("Render Monitor")
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .foregroundStyle(.white)
                Text(summary)
                    .font(.system(.subheadline, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            ZStack {
                Brand.night
                RadialGradient(colors: [Brand.orange.opacity(0.25), .clear], center: .leading,
                               startRadius: 0, endRadius: 260)
            }
        )
    }

    private var summary: String {
        let active = store.activeJobs
        guard !active.isEmpty else {
            return store.jobs.isEmpty ? "Waiting for Blender renders" : "No active renders"
        }
        let states = active.map { $0.state(now: store.now) }
        var parts = ["\(states.filter { $0 == .rendering }.count) rendering"]
        let queued = states.filter { $0 == .queued }.count
        let paused = states.filter { $0 == .paused }.count
        if queued > 0 { parts.append("\(queued) queued") }
        if paused > 0 { parts.append("\(paused) paused") }
        if let latest = active.compactMap(\.expectedFinish).max() {
            parts.append("done by \(Format.clock(latest, relativeTo: store.now))")
        }
        return parts.joined(separator: " · ")
    }
}

struct EmptyStateView: View {
    let store: JobStore

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
                .opacity(0.9)
            Text("No Blender renders yet").font(.system(.headline, design: .rounded))
            Text("Blender reports progress through a small hook script. Load it before your own script:")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Text("blender -b file.blend --python \"\(JobStore.hookURL.path)\" -a")
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            Text("For interactive Blender, install the same file as an add-on.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Copy --python Argument") { store.copyHookArgument() }
                Button("Show Hook Script") { store.revealHook() }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MenuBarContent: View {
    let store: JobStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if store.activeJobs.isEmpty {
            Text("No active renders")
        }
        ForEach(store.activeJobs) { job in
            let state = job.state(now: store.now)
            Button {
                store.togglePause(job)
            } label: {
                Text("\(state == .rendering ? "▶︎" : state == .paused ? "⏸" : "⏳") \(job.title): frame \(job.frameCounter), "
                    + "\(Format.duration(job.secondsRemaining(now: store.now))) left")
            }
            .help(state == .paused ? "Resume" : "Pause")
        }
        Divider()
        Button("Show Renders") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("r")
        Button("Quit") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

struct MenuBarLabel: View {
    let store: JobStore

    var body: some View {
        let active = store.renderingJobs
        if let first = active.first {
            let soonest = active.compactMap { $0.secondsRemaining(now: store.now) }.min()
            let text = active.count == 1
                ? "\(first.frameCounter) · \(Format.duration(soonest))"
                : "\(active.count) renders · \(Format.duration(soonest))"
            Label(text, systemImage: "film")
                .labelStyle(.titleAndIcon)
        } else {
            Image(systemName: "film")
        }
    }
}
