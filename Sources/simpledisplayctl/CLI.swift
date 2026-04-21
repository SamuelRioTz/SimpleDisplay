import Foundation
import SimpleDisplayCore

// simpledisplayctl — a thin wrapper that builds `simpledisplay://` URLs and
// hands them to `open(1)`. All real work lives in the running SimpleDisplay
// menu-bar app; this binary exists so shell scripts, SSH, Shortcuts, and
// launchd agents can drive it.

@main
struct CLI {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let head = args.first else {
            printUsage()
            exit(1)
        }
        let rest = Array(args.dropFirst())
        switch head {
        case "create":      runCreate(rest)
        case "remove":      runRemove(rest)
        case "reconfigure": runReconfigure(rest)
        case "open":        runOpen()
        case "status":      runStatus()
        case "-h", "--help", "help":
            printUsage()
        case "--version":
            print("simpledisplayctl \(CLIVersion.string)")
        default:
            fail("unknown subcommand '\(head)' (try `simpledisplayctl --help`)")
        }
    }
}

// MARK: - Subcommands

private func runCreate(_ args: [String]) {
    let opts = Options(args)
    guard let width = opts.int("--width") else { fail("missing --width") }
    guard let height = opts.int("--height") else { fail("missing --height") }
    var req = VirtualDisplayRequest(width: width, height: height)
    if let name = opts.string("--name") { req.name = name }
    if let refresh = opts.double("--refresh") { req.refreshRate = refresh }
    if opts.flag("--hidpi") { req.hiDPI = true }

    dispatch(.create(req))
}

private func runRemove(_ args: [String]) {
    let opts = Options(args)
    let id = opts.uint32("--id")
    let name = opts.string("--name")
    switch (id, name) {
    case (nil, nil):   fail("remove requires --id <N> or --name <S>")
    case (_?, _?):     fail("remove accepts only one of --id / --name")
    case (let id?, _): dispatch(.remove(.id(id)))
    case (_, let n?):  dispatch(.remove(.name(n)))
    }
}

private func runReconfigure(_ args: [String]) {
    let opts = Options(args)
    guard let id = opts.uint32("--id") else { fail("missing --id") }
    guard let width = opts.int("--width") else { fail("missing --width") }
    guard let height = opts.int("--height") else { fail("missing --height") }
    var req = VirtualDisplayRequest(width: width, height: height)
    if let refresh = opts.double("--refresh") { req.refreshRate = refresh }
    if opts.flag("--hidpi") { req.hiDPI = true }
    if let name = opts.string("--name") { req.name = name }

    dispatch(.reconfigure(id: id, request: req))
}

private func runOpen() {
    dispatch(.open)
}

private func runStatus() {
    let installed = InstallStatus.detect()
    print("installed: \(installed.installed ? "yes" : "no")")
    if let path = installed.path {
        print("path:      \(path)")
    }
    print("running:   \(installed.running ? "yes" : "no")")
    if let pid = installed.pid {
        print("pid:       \(pid)")
    }
    exit(installed.installed ? 0 : 2)
}

// MARK: - Dispatch

private func dispatch(_ command: URLCommand) {
    let url = command.url
    // `open` is the safest bridge — the system-provided one, not on $PATH manipulation,
    // and it launches the app if it's not running yet (URL scheme activation).
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = [url.absoluteString]
    do {
        try process.run()
    } catch {
        fail("failed to invoke /usr/bin/open: \(error.localizedDescription)")
    }
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        fail("open(1) exited \(process.terminationStatus) — is SimpleDisplay installed?")
    }
}

// MARK: - Usage

private func printUsage() {
    let usage = """
    simpledisplayctl — drive SimpleDisplay from the command line.

    USAGE:
      simpledisplayctl <command> [options]

    COMMANDS:
      create       --width N --height N [--name S] [--refresh N] [--hidpi]
      remove       --id N | --name S
      reconfigure  --id N --width N --height N [--refresh N] [--hidpi] [--name S]
      open         Focus the SimpleDisplay menu bar app.
      status       Print whether SimpleDisplay is installed / running.
      --version    Print CLI version.
      --help       Show this help.

    EXAMPLES:
      simpledisplayctl create --width 2732 --height 2048 --name "iPad Pro" --hidpi
      simpledisplayctl remove --name "iPad Pro"
      simpledisplayctl reconfigure --id 3 --width 1600 --height 1200

    NOTES:
      All actions are delegated to the running app via the simpledisplay:// URL
      scheme; `open(1)` will launch the app if it is not already running.
    """
    print(usage)
}

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}
