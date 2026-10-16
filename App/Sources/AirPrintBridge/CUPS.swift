import Foundation

/// Принтер (очередь CUPS).
struct Printer: Identifiable, Hashable {
    let id: String      // имя очереди CUPS
    let info: String    // человекочитаемое описание (модель)
}

enum Shell {
    /// Запускает команду и возвращает stdout (stderr отбрасывается).
    @discardableResult
    static func run(_ path: String, _ args: [String]) -> (out: String, status: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return ("", -1) }
        // Читаем до EOF до waitUntilExit, чтобы не заблокироваться на заполненном pipe
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(decoding: data, as: UTF8.self), p.terminationStatus)
    }
}

enum CUPS {
    /// Допустимое имя очереди CUPS (защита от инъекций в shell/AppleScript).
    static func isSafeName(_ s: String) -> Bool {
        !s.isEmpty && s.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil
    }

    /// Список очередей. В `lpstat -a` имя — первое поле, это не зависит от языка системы.
    static func listPrinters() -> [Printer] {
        let out = Shell.run("/usr/bin/lpstat", ["-a"]).out
        var result: [Printer] = []
        for line in out.split(separator: "\n") {
            guard let first = line.first, first != " ", first != "\t" else { continue }
            let name = String(line.split(separator: " ").first ?? "")
            guard isSafeName(name) else { continue }
            result.append(Printer(id: name, info: info(for: name)))
        }
        return result
    }

    /// printer-info из lpoptions (не локализуется); при неудаче — имя очереди.
    static func info(for queue: String) -> String {
        let out = Shell.run("/usr/bin/lpoptions", ["-p", queue]).out
            .replacingOccurrences(of: "\n", with: " ")
        if let r = out.range(of: "printer-info='") {
            let rest = out[r.upperBound...]
            if let end = rest.firstIndex(of: "'") { return String(rest[..<end]) }
        } else if let r = out.range(of: "printer-info=") {
            let rest = out[r.upperBound...]
            let word = rest.prefix { $0 != " " }
            if !word.isEmpty { return String(word) }
        }
        return queue
    }

    /// Расшарена ли очередь в CUPS.
    static func isShared(_ queue: String) -> Bool {
        Shell.run("/usr/bin/lpoptions", ["-p", queue]).out.contains("printer-is-shared=true")
    }

    /// Включает общий доступ к очереди. Нужны права администратора — системный запрос пароля.
    /// Возвращает текст ошибки или nil.
    static func enableSharing(_ queue: String) -> String? {
        guard isSafeName(queue) else { return "Недопустимое имя принтера" }
        let cmd = "/usr/sbin/cupsctl --share-printers; /usr/sbin/lpadmin -p \(queue) -o printer-is-shared=true"
        let script = "do shell script \"\(cmd)\" with administrator privileges"
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
        if let err = err {
            // -128 — пользователь отменил запрос пароля
            if (err[NSAppleScript.errorNumber] as? Int) == -128 { return "Запрос пароля отменён" }
            return (err[NSAppleScript.errorMessage] as? String) ?? "Не удалось включить общий доступ"
        }
        return nil
    }
}
