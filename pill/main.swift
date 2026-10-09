import AppKit
import Combine
import SwiftUI

struct Entry: Identifiable, Decodable, Equatable {
    var id: String { file }
    var file = ""
    var appTitle: String?
    var appSessionId: String?
    let project: String
    let branch: String?
    let title: String?
    var state: String
    var text: String
    let updatedAt: Double

    enum CodingKeys: String, CodingKey { case project, branch, title, state, text, updatedAt }

    var priority: Int {
        ["waiting": 0, "asking": 0, "working": 1, "thinking": 1, "done": 2, "idle": 3][state] ?? 4
    }

    var color: Color {
        switch state {
        case "waiting": return .orange
        case "asking": return .purple
        case "working", "thinking": return .blue
        case "done": return .green
        default: return .gray
        }
    }

    var heading: String {
        if let appTitle, !appTitle.isEmpty { return appTitle }
        if let title, !title.isEmpty { return title }
        return project
    }

    var link: URL? {
        guard let appSessionId else { return nil }
        return URL(string: "claude://code/continue?session=\(appSessionId)")
    }

    var place: String {
        [project, branch ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

final class Store: ObservableObject {
    @Published var entries: [Entry] = []
    @Published var bursts: [String: UUID] = [:]
    private let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/pet/sessions")
    private let staleAfter: Double = 12 * 3600 * 1000
    private let appSessions = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
    private var appIndex: [String: (title: String, id: String, isArchived: Bool, focusedAt: Double)] = [:]
    private var appIndexedAt = Date.distantPast
    // idle-сессии старше первого запуска пилюли не показываем: это старые открытые вкладки
    private let firstOpenedAt: Double = {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "firstOpenedAt") == nil {
            defaults.set(Date().timeIntervalSince1970 * 1000, forKey: "firstOpenedAt")
        }
        return defaults.double(forKey: "firstOpenedAt")
    }()
    // file → updatedAt скрытой записи: новая запись сессии снова её покажет
    private var dismissed = UserDefaults.standard.dictionary(forKey: "dismissed") as? [String: Double] ?? [:]

    func dismiss(_ entry: Entry) {
        dismissed[entry.file] = entry.updatedAt
        UserDefaults.standard.set(dismissed, forKey: "dismissed")
        appIndexedAt = .distantPast
        reload()
    }

    init() {
        reload()
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.reload() }
    }

    // Внутренний формат desktop-приложения: может поменяться с обновлением
    private func reindexAppSessions() {
        guard Date().timeIntervalSince(appIndexedAt) > 3 else { return }
        appIndexedAt = Date()
        var index: [String: (title: String, id: String, isArchived: Bool, focusedAt: Double)] = [:]
        let walker = FileManager.default.enumerator(at: appSessions, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            guard url.lastPathComponent.hasPrefix("local_"), url.pathExtension == "json",
                  let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cli = json["cliSessionId"] as? String,
                  let id = json["sessionId"] as? String else { continue }
            index[cli] = (json["title"] as? String ?? "", id, json["isArchived"] as? Bool ?? false, json["lastFocusedAt"] as? Double ?? 0)
        }
        appIndex = index
    }

    func reload() {
        reindexAppSessions()
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let now = Date().timeIntervalSince1970 * 1000
        let next = files.filter { $0.pathExtension == "json" }.compactMap { url -> Entry? in
            guard let data = try? Data(contentsOf: url),
                  var entry = try? JSONDecoder().decode(Entry.self, from: data),
                  entry.state != "ended",
                  entry.state != "idle" || entry.updatedAt >= firstOpenedAt,
                  now - entry.updatedAt < staleAfter else { return nil }
            entry.file = url.lastPathComponent
            let app = appIndex[url.deletingPathExtension().lastPathComponent]
            if app?.isArchived == true { return nil }
            // «готово» — непросмотренный результат: после открытия беседы он становится «жду задачу»
            if entry.state == "done", (app?.focusedAt ?? 0) > entry.updatedAt {
                entry.state = "idle"
                entry.text = "жду задачу"
            }
            if ["idle", "done"].contains(entry.state), dismissed[entry.file] == entry.updatedAt { return nil }
            entry.appTitle = app?.title
            entry.appSessionId = app?.id
            return entry
        }.sorted { ($0.priority, -$0.updatedAt) < ($1.priority, -$1.updatedAt) }
        guard next != entries else { return }
        let before = Dictionary(entries.map { ($0.file, $0.state) }, uniquingKeysWith: { a, _ in a })
        for entry in next where entry.state == "done" && before[entry.file] != nil && before[entry.file] != "done" {
            let token = UUID()
            bursts[entry.file] = token
            // Жетон одноразовый: иначе пересоздание строки при любой смене списка повторяет конфетти
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                if self?.bursts[entry.file] == token { self?.bursts[entry.file] = nil }
            }
        }
        withAnimation(.spring(duration: 0.45, bounce: 0.25)) { entries = next }
    }
}

let activeStates: Set<String> = ["waiting", "asking", "working", "thinking"]
let attentionStates: Set<String> = ["waiting", "asking"]
let pillMargin: CGFloat = 16

struct Dot: View {
    let color: Color
    let isActive: Bool
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .scaleEffect(isActive && pulse ? 1.25 : 1)
            .opacity(isActive && pulse ? 0.45 : 1)
            .animation(.easeInOut(duration: 0.35), value: color)
            .animation(isActive ? .easeInOut(duration: 0.8).repeatForever() : .default, value: pulse)
            .onAppear { pulse = true }
    }
}

struct ConfettiBurst: View {
    private static let colors: [Color] = [.pink, .yellow, .green, .blue, .purple, .orange]
    private let pieces: [(angle: Double, distance: CGFloat, color: Color, spin: Double)] = (0..<14).map { i in
        (Double(i) / 14 * 2 * .pi + .random(in: -0.2...0.2), .random(in: 14...26), colors[i % colors.count], .random(in: -180...180))
    }
    @State private var isFlying = false

    var body: some View {
        ZStack {
            ForEach(pieces.indices, id: \.self) { i in
                let piece = pieces[i]
                RoundedRectangle(cornerRadius: 1)
                    .fill(piece.color)
                    .frame(width: 3, height: 5)
                    .rotationEffect(.degrees(isFlying ? piece.spin : 0))
                    .offset(x: isFlying ? cos(piece.angle) * piece.distance : 0,
                            y: isFlying ? sin(piece.angle) * piece.distance + 6 : 0)
                    .opacity(isFlying ? 0 : 1)
            }
        }
        .allowsHitTesting(false)
        .onAppear { withAnimation(.easeOut(duration: 0.9)) { isFlying = true } }
    }
}

// Пилюля подпрыгивает раз в пару секунд, пока сессия ждёт человека
struct AttentionBounce: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        if isOn {
            content.keyframeAnimator(initialValue: 0.0, repeating: true) { view, y in
                view.offset(y: y)
            } keyframes: { _ in
                KeyframeTrack {
                    SpringKeyframe(-5, duration: 0.18)
                    SpringKeyframe(0, duration: 0.5, spring: .bouncy)
                    LinearKeyframe(0, duration: 1.8)
                }
            }
        } else {
            content
        }
    }
}

struct PillView: View {
    @ObservedObject var store: Store
    @State private var isHovered = false
    @State private var isBreathing = false

    private var lead: Entry? { store.entries.first }
    private var glow: Color { lead?.color ?? .gray }
    private var isActive: Bool { lead.map { activeStates.contains($0.state) } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if store.entries.isEmpty {
                row(entry: nil, heading: "Claude", text: "нет активных сессий", place: "", dot: Dot(color: .gray, isActive: false))
                    .onTapGesture { open(nil) }
            }
            ForEach(store.entries) { entry in
                row(entry: entry, heading: entry.heading, text: entry.text, place: entry.place,
                    dot: Dot(color: entry.color, isActive: activeStates.contains(entry.state)))
                    .contentShape(Rectangle())
                    .onTapGesture { open(entry.link) }
                    .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                            removal: .opacity.combined(with: .scale(scale: 0.9))))
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 24)
        .padding(.vertical, 7)
        // Тёмная подложка поверх материала: над светлыми окнами полупрозрачный фон съедал текст
        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(isActive ? glow.opacity(isBreathing ? 0.55 : 0.2) : .white.opacity(0.12)))
        .overlay(alignment: .topTrailing) {
            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Закрыть пилюлю")
            .padding(8)
            .opacity(isHovered ? 1 : 0)
        }
        .shadow(color: isActive ? glow.opacity(isBreathing ? 0.45 : 0.15) : .black.opacity(0.2), radius: isBreathing ? 9 : 5)
        .scaleEffect(isActive && isBreathing ? 1.015 : 1)
        .modifier(AttentionBounce(isOn: lead.map { attentionStates.contains($0.state) } ?? false))
        .animation(.easeInOut(duration: 0.4), value: glow)
        .animation(.easeInOut(duration: 0.2), value: isHovered)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.8).repeatForever()) { isBreathing = true }
        }
        .onHover { isHovered = $0 }
        .fixedSize()
        .padding(pillMargin)
    }

    private func open(_ link: URL?) {
        NSWorkspace.shared.open(link ?? URL(fileURLWithPath: "/Applications/Claude.app"))
    }

    private func row(entry: Entry?, heading: String, text: String, place: String, dot: Dot) -> some View {
        Row(entry: entry, onDismiss: { store.dismiss($0) }) {
            rowContent(entry: entry, heading: heading, text: text, place: place, dot: dot)
        }
    }

    private func rowContent(entry: Entry?, heading: String, text: String, place: String, dot: Dot) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 8) {
                dot.overlay {
                    if let entry, let token = store.bursts[entry.file] {
                        ConfettiBurst().id(token)
                    }
                }
                Text(heading).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            }
            Group {
                Text(text).font(.system(size: 11)).foregroundStyle(.white.opacity(0.82))
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.25), value: text)
                if !place.isEmpty {
                    Text(place).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.62))
                }
            }
            .lineLimit(1)
            .padding(.leading, 16)
        }
        .frame(maxWidth: 220, alignment: .leading)
    }
}

struct Row<Content: View>: View {
    let entry: Entry?
    let onDismiss: (Entry) -> Void
    @ViewBuilder let content: Content
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            content
            if let entry, ["idle", "done"].contains(entry.state) {
                Button { onDismiss(entry) } label: {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(.red))
                }
                .buttonStyle(.plain)
                .help("Убрать из списка")
                .opacity(isHovered ? 1 : 0)
            }
        }
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: NSPanel!
    let store = Store()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let host = NSHostingView(rootView: PillView(store: store))
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false

        let menu = NSMenu()
        menu.addItem(withTitle: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        host.menu = menu

        panel.setContentSize(host.fittingSize)
        if !panel.setFrameUsingName("ClaudePill"), let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: f.maxX - host.fittingSize.width - 8, y: f.maxY - 8))
        }
        panel.setFrameAutosaveName("ClaudePill")
        panel.orderFrontRegardless()

        store.$entries.receive(on: RunLoop.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.fit() }
        }.store(in: &bag)
    }

    var bag = Set<AnyCancellable>()

    private func fit() {
        guard let host = panel.contentView else { return }
        let size = host.fittingSize
        let top = panel.frame.maxY
        panel.setFrame(NSRect(x: panel.frame.minX, y: top - size.height, width: size.width, height: size.height), display: true)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
