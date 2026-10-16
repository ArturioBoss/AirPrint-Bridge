import Foundation
import AppKit
import ServiceManagement

/// Состояние приложения: список принтеров, настройки, управление Bonjour-объявлениями.
@MainActor
final class BridgeStore: ObservableObject {
    static let shared = BridgeStore()

    private let defaults = UserDefaults.standard
    private enum Key {
        static let showIcon = "showMenuBarIcon"
        static let master = "masterEnabled"
        static let shareNew = "shareNewPrinters"
        static let color = "advertiseColor"
        static let duplex = "advertiseDuplex"
        static let enabled = "enabledPrinters"      // [String: Bool]
        static let sharedOK = "sharingConfigured"   // [String]
    }

    // MARK: Настройки

    /// Хранится только в UserDefaults; в интерфейсе привязывается через @AppStorage (ключ "showMenuBarIcon")
    var showMenuBarIcon: Bool { defaults.bool(forKey: Key.showIcon) }
    @Published var masterEnabled: Bool { didSet { defaults.set(masterEnabled, forKey: Key.master); reconcile() } }
    @Published var shareNew: Bool { didSet { defaults.set(shareNew, forKey: Key.shareNew) } }
    @Published var advertiseColor: Bool { didSet { defaults.set(advertiseColor, forKey: Key.color); reconcile() } }
    @Published var advertiseDuplex: Bool { didSet { defaults.set(advertiseDuplex, forKey: Key.duplex); reconcile() } }
    @Published private(set) var enabled: [String: Bool]

    // MARK: Состояние

    @Published private(set) var printers: [Printer] = []
    @Published private(set) var published: Set<String> = []
    @Published var errorMessage: String?
    @Published private(set) var launchAtLogin: Bool

    private struct Running { let process: Process; let signature: String }
    private var running: [String: Running] = [:]
    private var timer: Timer?
    private let hostName = ProcessInfo.processInfo.hostName

    private init() {
        defaults.register(defaults: [
            Key.master: true, Key.shareNew: false, Key.color: true, Key.duplex: true,
            Key.showIcon: true,
        ])
        // Убираем «осиротевшие» объявления от прошлого запуска (например, после аварийного завершения)
        Shell.run("/usr/bin/pkill", ["-f", "dns-sd -R .*_ipp._tcp,_universal"])
        masterEnabled = defaults.bool(forKey: Key.master)
        shareNew = defaults.bool(forKey: Key.shareNew)
        advertiseColor = defaults.bool(forKey: Key.color)
        advertiseDuplex = defaults.bool(forKey: Key.duplex)
        enabled = (defaults.dictionary(forKey: Key.enabled) as? [String: Bool]) ?? [:]
        launchAtLogin = SMAppService.mainApp.status == .enabled

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // willTerminate приходит на главном потоке; нужно выполнить синхронно, пока процесс жив
            MainActor.assumeIsolated { self?.stopAll() }
        }

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    var activeCount: Int { published.count }

    func isEnabled(_ p: Printer) -> Bool { enabled[p.id] ?? false }

    // MARK: Действия

    func setEnabled(_ on: Bool, for p: Printer) {
        guard isEnabled(p) != on else { return }   // см. Binding.deduped()
        enabled[p.id] = on
        defaults.set(enabled, forKey: Key.enabled)
        if on { ensureSharing(p.id) }
        reconcile()
    }

    func setLaunchAtLogin(_ on: Bool) {
        guard launchAtLogin != on else { return }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            errorMessage = "Автозапуск: \(error.localizedDescription). Перенесите приложение в «Программы»."
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Перечитывает список очередей CUPS (в фоне) и применяет настройки.
    func refresh() {
        Task.detached {
            let list = CUPS.listPrinters()
            await MainActor.run { self.apply(list) }
        }
    }

    private func apply(_ list: [Printer]) {
        var changed = false
        for p in list where enabled[p.id] == nil {
            // Новые принтеры: по умолчанию по настройке; сканеры — никогда автоматически
            let scanner = p.id.lowercased().contains("scan") || p.info.lowercased().contains("scan")
            enabled[p.id] = shareNew && !scanner
            changed = true
        }
        if changed { defaults.set(enabled, forKey: Key.enabled) }
        if list != printers { printers = list }
        reconcile()
    }

    // MARK: Общий доступ CUPS

    private func ensureSharing(_ queue: String) {
        if (defaults.stringArray(forKey: Key.sharedOK) ?? []).contains(queue) { return }
        Task.detached {
            let already = CUPS.isShared(queue)
            let err = already ? nil : CUPS.enableSharing(queue)
            await MainActor.run {
                if let err = err {
                    self.errorMessage = "«\(queue)»: \(err)"
                } else {
                    var done = Set(self.defaults.stringArray(forKey: Key.sharedOK) ?? [])
                    done.insert(queue)
                    self.defaults.set(Array(done), forKey: Key.sharedOK)
                }
            }
        }
    }

    // MARK: Bonjour (dns-sd)

    /// Приводит набор запущенных dns-sd к желаемому состоянию.
    private func reconcile() {
        let wanted: [Printer] = masterEnabled ? printers.filter { isEnabled($0) } : []
        let wantedIDs = Set(wanted.map(\.id))

        for (id, r) in running where !wantedIDs.contains(id) {
            r.process.terminate()
            running[id] = nil
        }
        for p in wanted {
            let sig = "\(p.info)|\(advertiseColor)|\(advertiseDuplex)"
            if let r = running[p.id] {
                if r.signature == sig && r.process.isRunning { continue }
                r.process.terminate()
                running[p.id] = nil
            }
            if let proc = startAdvertising(p) {
                running[p.id] = Running(process: proc, signature: sig)
            }
        }
        let now = Set(running.keys)
        if now != published { published = now }
    }

    private func startAdvertising(_ p: Printer) -> Process? {
        let urf = "CP1,IS1,MT1-3-4-5-8-11,OB10,PQ4,RS300-600,SRGB24,V1.4,W8" + (advertiseDuplex ? ",DM1" : "")
        let rp = "printers/\(p.id)"
        let args = [
            "-R", p.info, "_ipp._tcp,_universal", ".", "631",
            "txtvers=1", "qtotal=1",
            "rp=\(rp)", "ty=\(p.info)",
            "adminurl=http://\(hostName):631/\(rp)",
            "note=\(hostName)", "priority=10", "product=(\(p.info))",
            "pdl=application/octet-stream,application/pdf,image/urf,image/jpeg,image/png",
            "URF=\(urf)",
            "Color=\(advertiseColor ? "T" : "F")",
            "Duplex=\(advertiseDuplex ? "T" : "F")",
            "TLS=1.2", "Transparent=T", "Binary=T", "Fax=F",
            "kind=document,envelope,photo", "PaperMax=legal-A4", "air=none",
        ]
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/dns-sd")
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            return proc
        } catch {
            errorMessage = "Не удалось запустить dns-sd: \(error.localizedDescription)"
            return nil
        }
    }

    private func stopAll() {
        for (_, r) in running { r.process.terminate() }
        running.removeAll()
    }
}
