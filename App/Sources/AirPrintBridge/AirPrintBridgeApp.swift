import SwiftUI
import AppKit

enum AppInfo {
    static let name = "AirPrint Bridge"
    static let developer = "ArturiOS"
    static let email = "arturiosboss@gmail.com"
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}

extension Binding where Value: Equatable {
    /// Записывает значение только если оно изменилось. Переключатели в NSMenu вызывают сеттер
    /// при каждой перерисовке, а повторная запись в @Published снова перерисовывает вид — цикл.
    func deduped() -> Binding<Value> {
        Binding(get: { self.wrappedValue }, set: { if $0 != self.wrappedValue { self.wrappedValue = $0 } })
    }
}

/// Окно настроек на AppKit: открывается и из меню, и при повторном запуске приложения
/// (нужно, когда значок в строке меню скрыт).
@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView().environmentObject(BridgeStore.shared))
            let w = NSWindow(contentViewController: host)
            w.title = AppInfo.name
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Значок скрыт — показываем окно, иначе пользователь не поймёт, что приложение запущено
        if !BridgeStore.shared.showMenuBarIcon { SettingsWindow.shared.show() }
    }

    /// Повторный запуск из «Программ»/Launchpad/Spotlight
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindow.shared.show()
        return true
    }
}

@main
struct AirPrintBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = BridgeStore.shared
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true

    var body: some Scene {
        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuContent().environmentObject(store)
        } label: {
            Image(systemName: store.masterEnabled && store.activeCount > 0 ? "printer.fill" : "printer")
        }
        .menuBarExtraStyle(.menu)
    }
}

struct MenuContent: View {
    @EnvironmentObject var store: BridgeStore

    private func check(_ on: Bool) -> String { on ? "✓ " : "     " }

    var body: some View {
        // Кнопки вместо Toggle: привязки Toggle в NSMenu пересинхронизируются при каждом обновлении
        // и на macOS 15 зацикливают перерисовку.
        Button(check(store.masterEnabled) + "AirPrint включён") {
            store.masterEnabled.toggle()
        }

        Divider()

        if store.printers.isEmpty {
            Text("Принтеры не найдены")
        } else {
            Text("Принтеры")
            ForEach(store.printers) { p in
                Button(check(store.isEnabled(p)) + p.info) {
                    store.setEnabled(!store.isEnabled(p), for: p)
                }
                .disabled(!store.masterEnabled)
            }
        }

        Divider()

        Button("Настройки…") { SettingsWindow.shared.show() }
            .keyboardShortcut(",")

        Button("Выйти") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
