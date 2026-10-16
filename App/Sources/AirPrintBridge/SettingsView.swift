import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: BridgeStore
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $store.masterEnabled.deduped()) {
                    Label("Раздавать принтеры по AirPrint", systemImage: "airplayaudio")
                }
                Toggle(isOn: Binding(
                    get: { store.launchAtLogin },
                    set: { store.setLaunchAtLogin($0) }
                )) {
                    Label("Запускать при входе в систему", systemImage: "power")
                }
                Toggle(isOn: $store.shareNew.deduped()) {
                    Label("Раздавать новые принтеры автоматически", systemImage: "plus.circle")
                }
            } header: {
                Text("Общие")
            }

            Section {
                if store.printers.isEmpty {
                    HStack {
                        Spacer()
                        VStack(spacing: 6) {
                            Image(systemName: "printer.dotmatrix")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                            Text("Принтеры не найдены")
                            Text("Добавьте принтер в «Системные настройки → Принтеры и сканеры»")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.vertical, 8)
                        Spacer()
                    }
                } else {
                    ForEach(store.printers) { p in
                        PrinterRow(printer: p)
                    }
                }
            } header: {
                HStack {
                    Text("Принтеры")
                    Spacer()
                    Button {
                        store.refresh()
                    } label: {
                        Label("Обновить", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .labelStyle(.iconOnly)
                    .help("Обновить список принтеров")
                }
            } footer: {
                Text("Включённые принтеры видны на iPhone и iPad. Выключенные остаются только на этом Mac.")
            }

            Section {
                Toggle("Объявлять цветную печать", isOn: $store.advertiseColor.deduped())
                Toggle("Объявлять двустороннюю печать", isOn: $store.advertiseDuplex.deduped())
            } header: {
                Text("Возможности, которые видит iOS")
            } footer: {
                Text("У принтера без дуплекса двусторонняя печать будет ручной: принтер ждёт, пока вы перевернёте лист.")
            }

            Section {
                Toggle(isOn: $showMenuBarIcon) {
                    Label("Показывать значок в строке меню", systemImage: "menubar.rectangle")
                }
            } header: {
                Text("Строка меню")
            } footer: {
                Text("Если значок скрыт, приложение продолжает работать. Чтобы открыть настройки, запустите AirPrint Bridge из «Программ» или Launchpad.")
            }

            Section {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AppInfo.name).font(.headline)
                        Text("Версия \(AppInfo.version)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                LabeledContent("Разработчик", value: AppInfo.developer)
                LabeledContent("Поддержка") {
                    Link(AppInfo.email, destination: URL(string: "mailto:\(AppInfo.email)")!)
                }
            } header: {
                Text("О приложении")
            }

            if let error = store.errorMessage {
                Section {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        Text(error).font(.callout)
                        Spacer()
                        Button("Скрыть") { store.errorMessage = nil }
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 640)
    }
}

struct PrinterRow: View {
    @EnvironmentObject var store: BridgeStore
    let printer: Printer

    var body: some View {
        let live = store.published.contains(printer.id)
        HStack(spacing: 10) {
            Image(systemName: "printer.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(printer.info)
                HStack(spacing: 5) {
                    Circle()
                        .fill(live ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 7, height: 7)
                    Text(live ? "Доступен по AirPrint" : "Не раздаётся")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { store.isEnabled(printer) },
                set: { store.setEnabled($0, for: printer) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .disabled(!store.masterEnabled)
        }
        .padding(.vertical, 2)
    }
}
