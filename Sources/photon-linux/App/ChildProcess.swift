#if os(Linux)
import CGtk3
import Foundation

/// A child process on the GLib main loop: posix_spawn with pipes for stdin and stdout+stderr, output lines and the exit
/// delivered by GLib sources (g_unix_fd_add, g_child_watch_add) on the main thread. Foundation's Process is not used:
/// its exit notification did not arrive inside the GTK loop (and `waitUntilExit` hung the same way in the host,
/// StaticBackground.spawn).
final class ChildProcess {
    let pid: pid_t
    private var stdinFD: Int32
    private var stdoutFD: Int32
    private var buffer = [UInt8]()
    private var fdSource: guint = 0
    private(set) var running = true
    let arguments: [String]
    var onLine: ((String) -> Void)?
    var onExit: ((Int32) -> Void)?

    init?(_ args: [String], environment: [String: String]? = nil) {
        var inPipe: [Int32] = [0, 0], outPipe: [Int32] = [0, 0]
        guard pipe(&inPipe) == 0, pipe(&outPipe) == 0 else { return nil }
        var actions = posix_spawn_file_actions_t()
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, inPipe[0], 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 2)
        for fd in [inPipe[0], inPipe[1], outPipe[0], outPipe[1]] { posix_spawn_file_actions_addclose(&actions, fd) }
        var argv = args.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let env = (environment ?? ProcessInfo.processInfo.environment).map { strdup("\($0.key)=\($0.value)") }
        var envp = env + [nil]
        defer { env.forEach { free($0) } }
        var p: pid_t = 0
        let rc = posix_spawn(&p, args[0], &actions, nil, &argv, &envp)
        close(inPipe[0]); close(outPipe[1])
        guard rc == 0 else { close(inPipe[1]); close(outPipe[0]); return nil }
        pid = p
        arguments = args
        stdinFD = inPipe[1]
        stdoutFD = outPipe[0]
        _ = fcntl(stdoutFD, F_SETFL, fcntl(stdoutFD, F_GETFL) | O_NONBLOCK)
        _ = fcntl(stdinFD, F_SETFD, FD_CLOEXEC)
        _ = fcntl(stdoutFD, F_SETFD, FD_CLOEXEC)
        // SIGPIPE on a write to a host that is gone must not end the app.
        signal(SIGPIPE, SIG_IGN)
        let me = Unmanaged.passRetained(self).toOpaque()
        fdSource = g_unix_fd_add_full(G_PRIORITY_DEFAULT, stdoutFD, GIOCondition(rawValue: G_IO_IN.rawValue | G_IO_HUP.rawValue | G_IO_ERR.rawValue),
                                      { fd, _, data in
                                          Unmanaged<ChildProcess>.fromOpaque(data!).takeUnretainedValue().readAvailable() ? 1 : 0
                                      }, me, nil)
        g_child_watch_add_full(G_PRIORITY_DEFAULT, p, { _, status, data in
            let c = Unmanaged<ChildProcess>.fromOpaque(data!).takeRetainedValue()
            _ = c.readAvailable()
            c.finish(status)
        }, me, nil)
    }

    /// Reads what is there; false (remove the source) at end of file.
    private func readAvailable() -> Bool {
        guard stdoutFD >= 0 else { return false }
        var chunk = [UInt8](repeating: 0, count: 8192)
        var eof = false
        while true {
            let n = read(stdoutFD, &chunk, chunk.count)
            if n > 0 { buffer += chunk[0..<n]; continue }
            if n == 0 { eof = true }
            break
        }
        while let nl = buffer.firstIndex(of: 10) {
            let line = String(decoding: buffer[..<nl], as: UTF8.self)
            buffer.removeSubrange(...nl)
            onLine?(line)
        }
        if eof {
            if !buffer.isEmpty { onLine?(String(decoding: buffer, as: UTF8.self)); buffer = [] }
            close(stdoutFD)
            stdoutFD = -1
            fdSource = 0
            return false
        }
        return true
    }

    private func finish(_ status: Int32) {
        running = false
        if fdSource != 0 { g_source_remove(fdSource); fdSource = 0 }
        if stdoutFD >= 0 { close(stdoutFD); stdoutFD = -1 }
        closeInput()
        g_spawn_close_pid(pid)
        // Exit code, or 128 + signal like a shell.
        let code = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        onExit?(code)
    }

    func send(_ line: String) {
        guard stdinFD >= 0 else { return }
        let bytes = Array((line + "\n").utf8)
        _ = bytes.withUnsafeBytes { write(stdinFD, $0.baseAddress, $0.count) }
    }

    func closeInput() {
        if stdinFD >= 0 { close(stdinFD); stdinFD = -1 }
    }

    func terminate() { if running { kill(pid, SIGTERM) } }

    /// Runs to completion and returns stdout (short helper commands such as `desktop --list-outputs`).
    static func capture(_ args: [String], timeout: Double = 10) -> String {
        var outPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0 else { return "" }
        var actions = posix_spawn_file_actions_t()
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addclose(&actions, outPipe[0])
        posix_spawn_file_actions_addclose(&actions, outPipe[1])
        var argv = args.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        guard posix_spawn(&pid, args[0], &actions, nil, &argv, environ) == 0 else { close(outPipe[0]); close(outPipe[1]); return "" }
        close(outPipe[1])
        var data = [UInt8](), chunk = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(timeout)
        var pfd = pollfd(fd: outPipe[0], events: Int16(POLLIN), revents: 0)
        while Date() < deadline {
            guard poll(&pfd, 1, 200) >= 0 else { break }
            if pfd.revents == 0 { continue }
            let n = read(outPipe[0], &chunk, chunk.count)
            if n <= 0 { break }
            data += chunk[0..<n]
        }
        close(outPipe[0])
        var status: Int32 = 0
        if waitpid(pid, &status, WNOHANG) == 0 { kill(pid, SIGKILL); waitpid(pid, &status, 0) }
        return String(decoding: data, as: UTF8.self)
    }
}
#endif
