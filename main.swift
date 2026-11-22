// NotchRAM : jauge RAM collée à l'encoche, dépliée au survol avec les process les plus gourmands.
import AppKit
import SwiftUI
import Darwin

// MARK: - Mesures

struct Proc: Identifiable { let id: pid_t; let name: String; let bytes: UInt64 }

struct Snapshot {
    var used: UInt64 = 0
    var total: UInt64 = ProcessInfo.processInfo.physicalMemory
    var swap: UInt64 = 0
    var pressure: Int32 = 1   // kern.memorystatus_vm_pressure_level : 1 normale, 2 élevée, 4 critique
    var top: [Proc] = []
    var percent: Int { total == 0 ? 0 : Int((Double(used) / Double(total) * 100).rounded()) }
}

func sysctlRead<T>(_ name: String, _ value: inout T) -> Bool {
    var size = MemoryLayout<T>.size
    return sysctlbyname(name, &value, &size, nil, 0) == 0
}

// Même formule que « Mémoire utilisée » du Moniteur d'activité : app + câblée + compressée.
func memoryUsed() -> UInt64 {
    var s = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
    let kr = withUnsafeMutablePointer(to: &s) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
    }
    guard kr == KERN_SUCCESS else { return 0 }
    let app = s.internal_page_count > s.purgeable_count ? UInt64(s.internal_page_count - s.purgeable_count) : 0
    return (app + UInt64(s.wire_count) + UInt64(s.compressor_page_count)) * UInt64(getpagesize())
}

func processName(_ pid: pid_t) -> String {
    if let n = NSRunningApplication(processIdentifier: pid)?.localizedName { return n }
    var buf = [CChar](repeating: 0, count: 256)
    proc_name(pid, &buf, UInt32(buf.count))
    return String(cString: buf)
}

// shortcut: seuls les process lisibles sans root (les tiens) sont listés ; WindowServer, kernel_task etc. n'apparaissent pas.
func topProcesses(_ n: Int) -> [Proc] {
    var pids = [pid_t](repeating: 0, count: Int(proc_listallpids(nil, 0)) + 64)
    let got = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
    let me = getpid()
    var all: [(pid_t, UInt64)] = []
    for pid in pids.prefix(max(got, 0)) where pid > 0 && pid != me {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        if rc == 0 { all.append((pid, info.ri_phys_footprint)) }
    }
    return all.sorted { $0.1 > $1.1 }.prefix(n).map { Proc(id: $0.0, name: processName($0.0), bytes: $0.1) }
}

func snapshot(withTop: Bool) -> Snapshot {
    var s = Snapshot()
    s.used = memoryUsed()
    var sw = xsw_usage()
    if sysctlRead("vm.swapusage", &sw) { s.swap = sw.xsu_used }
    var lvl: Int32 = 1
    if sysctlRead("kern.memorystatus_vm_pressure_level", &lvl) { s.pressure = lvl }
    if withTop { s.top = topProcesses(5) }
    return s
}

let bytesFmt: ByteCountFormatter = { let f = ByteCountFormatter(); f.countStyle = .memory; return f }()
func fmt(_ b: UInt64) -> String { bytesFmt.string(fromByteCount: Int64(b)) }

// MARK: - Modèle

enum Size {
    static let ear: CGFloat = 64      // largeur de chaque « oreille » à côté de l'encoche
    static let openW: CGFloat = 380
    static let openH: CGFloat = 272
}

final class Model: ObservableObject {
    @Published var snap = Snapshot()
    @Published var expanded = false
    @Published var armed: pid_t?
    @Published var notchW: CGFloat = 0
    @Published var notchH: CGFloat = 32

    func refresh() { snap = snapshot(withTop: expanded) }

    // Premier clic arme, second clic quitte : un clic égaré ne ferme rien.
    func tapQuit(_ pid: pid_t) {
        guard armed == pid else {
            armed = pid
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in if self?.armed == pid { self?.armed = nil } }
            return
        }
        armed = nil
        quitProcess(pid)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.refresh() }
    }
}

/// Une vraie app (Dock) reçoit seulement terminate() : elle peut proposer d'enregistrer, on ne la force jamais.
/// Le reste (services XPC comme « Contenu web Safari », apps de barre des menus, processus nus) ignore souvent
/// cette demande : SIGTERM s'il tourne encore 1,5 s après.
func quitProcess(_ pid: pid_t, after delay: Double = 1.5) {
    let app = NSRunningApplication(processIdentifier: pid)
    if let app, app.activationPolicy == .regular { app.terminate(); return }
    app?.terminate()
    DispatchQueue.main.asyncAfter(deadline: .now() + (app == nil ? 0 : delay)) {
        if kill(pid, 0) == 0 { kill(pid, SIGTERM) }
    }
}

// MARK: - Vue

struct PressureStyle {
    let color: Color, label: String
    init(_ level: Int32) {
        switch level {
        case 4: (color, label) = (Color(nsColor: .systemRed), "Pression critique")
        case 2: (color, label) = (Color(nsColor: .systemOrange), "Pression élevée")
        default: (color, label) = (Color(nsColor: .systemGreen), "Pression normale")
        }
    }
}

let ink = Color(white: 0.93)
let inkDim = Color(white: 0.56)

struct NotchView: View {
    @ObservedObject var m: Model

    var body: some View {
        let s = m.snap, p = PressureStyle(s.pressure)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                gauge(s, p).frame(width: Size.ear)
                Spacer(minLength: m.notchW)
                Text("\(s.percent) %").font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(ink).frame(width: Size.ear)
            }
            .frame(height: m.notchH)
            .padding(.horizontal, m.expanded ? 12 : 0)

            if m.expanded { details(s, p).transition(.opacity) }
        }
        .frame(width: m.expanded ? Size.openW : m.notchW + 2 * Size.ear,
               height: m.expanded ? Size.openH : m.notchH, alignment: .top)
        .background(Color.black)   // noir pur voulu : se fondre dans la découpe matérielle
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: m.expanded ? 20 : 10, bottomTrailingRadius: m.expanded ? 20 : 10))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.28), value: m.expanded)
    }

    func gauge(_ s: Snapshot, _ p: PressureStyle) -> some View {
        Capsule().fill(Color(white: 0.22)).frame(width: 34, height: 6)
            .overlay(alignment: .leading) {
                Capsule().fill(p.color).frame(width: max(6, 34 * CGFloat(s.percent) / 100), height: 6)
            }
            .accessibilityLabel("Mémoire \(s.percent) %, \(p.label)")
    }

    func details(_ s: Snapshot, _ p: PressureStyle) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(fmt(s.used)).font(.system(size: 22, weight: .semibold).monospacedDigit()).foregroundStyle(ink)
                Text("sur \(fmt(s.total))").font(.system(size: 12).monospacedDigit()).foregroundStyle(inkDim)
                Spacer()
                HStack(spacing: 5) {
                    Circle().fill(p.color).frame(width: 7, height: 7)
                    Text(p.label).font(.system(size: 11, weight: .medium)).foregroundStyle(ink)
                }
            }
            Text("Swap utilisé : \(fmt(s.swap))").font(.system(size: 11).monospacedDigit()).foregroundStyle(inkDim)
                .padding(.top, 2)

            Rectangle().fill(Color(white: 0.16)).frame(height: 1).padding(.vertical, 10)

            if s.top.isEmpty {
                Text("Lecture des process…").font(.system(size: 12)).foregroundStyle(inkDim).frame(height: 26 * 5, alignment: .top)
            } else {
                ForEach(s.top) { row($0) }
            }

            Spacer(minLength: 8)
            HStack {
                Button("Ouvrir le Moniteur d'activité") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                }
                Spacer()
                Button("Fermer le widget") { NSApp.terminate(nil) }
            }
            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(inkDim)
        }
        .padding(.horizontal, 18).padding(.top, 6).padding(.bottom, 12)
    }

    func row(_ proc: Proc) -> some View {
        HStack(spacing: 10) {
            Text(proc.name).font(.system(size: 12)).foregroundStyle(ink).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Text(fmt(proc.bytes)).font(.system(size: 12).monospacedDigit()).foregroundStyle(inkDim)
            Button { m.tapQuit(proc.id) } label: {
                if m.armed == proc.id {
                    Text("Quitter ?").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 7).frame(height: 20).background(Capsule().fill(Color(nsColor: .systemRed)))
                } else {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(inkDim)
                        .frame(width: 20, height: 20).background(Circle().fill(Color(white: 0.14)))
                }
            }
            .buttonStyle(.plain)
            .help("Quitter \(proc.name)")
            .accessibilityLabel(m.armed == proc.id ? "Confirmer : quitter \(proc.name)" : "Quitter \(proc.name)")
        }
        .frame(height: 26)
    }
}

// MARK: - Fenêtre

final class Hosting<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }  // le clic marche sans activer l'app
}

final class Controller {
    let m = Model()
    let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    var collapsedRect = NSRect.zero, openRect = NSRect.zero
    var leftAt: Date?
    var timers: [Timer] = []

    init(forceOpen: Bool) {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = Hosting(rootView: NotchView(m: m))
        layout()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.layout() }
        m.refresh()
        panel.orderFrontRegardless()
        if forceOpen { setExpanded(true); return }   // --open : mode capture pour la QA
        timers.append(Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.m.refresh() })
        // Survol par sondage de la souris : fiable même quand l'app n'est pas active.
        timers.append(Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.trackMouse() })
    }

    func layout() {
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
        let f = screen.frame
        if screen.safeAreaInsets.top > 0, let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            m.notchW = f.width - l.width - r.width
            m.notchH = screen.safeAreaInsets.top
        } else {   // écran sans encoche (capot fermé) : pastille centrée sous la barre des menus
            m.notchW = 0
            m.notchH = NSStatusBar.system.thickness
        }
        openRect = NSRect(x: f.midX - Size.openW / 2, y: f.maxY - Size.openH, width: Size.openW, height: Size.openH)
        let cw = m.notchW + 2 * Size.ear
        collapsedRect = NSRect(x: f.midX - cw / 2, y: f.maxY - m.notchH, width: cw, height: m.notchH + 2)
        panel.setFrame(openRect, display: true)
        panel.ignoresMouseEvents = !m.expanded
    }

    func setExpanded(_ on: Bool) {
        guard m.expanded != on else { return }
        m.expanded = on
        if !on { m.armed = nil }
        panel.ignoresMouseEvents = !on   // repliée, la pastille ne bloque aucun clic de la barre des menus
        m.refresh()
    }

    func trackMouse() {
        let p = NSEvent.mouseLocation
        if !m.expanded {
            if collapsedRect.contains(p) { setExpanded(true) }
        } else if openRect.contains(p) {
            leftAt = nil
        } else if let t = leftAt {
            if Date().timeIntervalSince(t) > 0.35 { setExpanded(false); leftAt = nil }
        } else {
            leftAt = Date()
        }
    }
}

// MARK: - Lancement

if CommandLine.arguments.contains("--selftest") {
    let s = snapshot(withTop: true)
    precondition(s.total > 0 && s.used > 0 && s.used <= s.total, "used/total incohérents")
    precondition([1, 2, 4].contains(s.pressure), "niveau de pression inattendu : \(s.pressure)")
    precondition(!s.top.isEmpty && zip(s.top, s.top.dropFirst()).allSatisfy { $0.bytes >= $1.bytes }, "top process vide ou mal trié")
    print("OK  \(fmt(s.used)) / \(fmt(s.total)) (\(s.percent) %)  pression=\(s.pressure)  swap=\(fmt(s.swap))")
    s.top.forEach { print("    \($0.name)  \(fmt($0.bytes))") }
    // Quitter un processus qui n'est pas une app : il doit disparaître (régression du 2026-11-22).
    let sleeper = Process()
    sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep"); sleeper.arguments = ["30"]
    try! sleeper.run()
    quitProcess(sleeper.processIdentifier)
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    sleeper.waitUntilExit()
    precondition(sleeper.terminationReason == .uncaughtSignal && sleeper.terminationStatus == SIGTERM, "quitProcess n'a pas arrêté le processus")
    print("OK  quitProcess arrête un processus qui n'est pas une app")
    exit(0)
}

// --capture <fichier.png> : rend le panneau déplié en image, sans écran ni autorisation d'enregistrement (aperçu du README)
if let i = CommandLine.arguments.firstIndex(of: "--capture"), i + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated {
        let m = Model()
        m.expanded = true; m.notchW = 200; m.snap = snapshot(withTop: true)
        let r = ImageRenderer(content: NotchView(m: m).frame(width: Size.openW, height: Size.openH)
            .padding(.horizontal, 40).padding(.bottom, 40).background(Color(white: 0.22)))
        r.scale = 2
        guard let img = r.cgImage, let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]),
              (try? png.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))) != nil else { exit(1) }
    }
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = Controller(forceOpen: CommandLine.arguments.contains("--open"))
app.run()
