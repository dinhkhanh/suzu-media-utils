import Darwin
import Foundation

/// A child process started with posix_spawn, its arguments and environment passed byte for byte.
///
/// Foundation's `Process` hands every argument and environment value to the child in the file system's
/// decomposed form (an "Ị" becomes I plus a combining dot), which is what macOS disks use and what nothing else
/// does: a Vietnamese folder name sent to the NAS through ssh and rsync then names a folder that isn't there, and
/// mkdir makes a second one next to the real one, looking the same. Anything whose arguments reach another
/// machine goes through here instead.
enum RawProcess {
    final class Child {
        let pid: pid_t
        let stdout: FileHandle
        let stderr: FileHandle
        init(pid: pid_t, stdout: FileHandle, stderr: FileHandle) { self.pid = pid; self.stdout = stdout; self.stderr = stderr }
    }

    struct Exit {
        var status: Int32
        /// Ended by a signal (status is then the signal number).
        var signaled: Bool
    }

    enum SpawnError: Error { case failed(Int32) }

    /// Starts `executable` with `arguments`; stdin is /dev/null, stdout and stderr are pipes read through the
    /// returned handles. `environment` nil: this process's own.
    static func spawn(_ executable: String, arguments: [String], environment: [String: String]? = nil) throws -> Child {
        let out = Pipe(), err = Pipe()
        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, out.fileHandleForWriting.fileDescriptor, 1)
        posix_spawn_file_actions_adddup2(&actions, err.fileHandleForWriting.fileDescriptor, 2)
        posix_spawn_file_actions_addclose(&actions, out.fileHandleForReading.fileDescriptor)
        posix_spawn_file_actions_addclose(&actions, err.fileHandleForReading.fileDescriptor)
        posix_spawn_file_actions_addclose(&actions, out.fileHandleForWriting.fileDescriptor)
        posix_spawn_file_actions_addclose(&actions, err.fileHandleForWriting.fileDescriptor)
        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // The child starts with no signals blocked or ignored, whatever this process has.
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigmask(&attr, &none)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT))
        let env = environment ?? ProcessInfo.processInfo.environment
        let argv = cStrings([executable] + arguments)
        let envp = cStrings(env.map { "\($0.key)=\($0.value)" })
        defer { free(argv); free(envp) }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &actions, &attr, argv, envp)
        try? out.fileHandleForWriting.close()
        try? err.fileHandleForWriting.close()
        guard rc == 0 else {
            try? out.fileHandleForReading.close()
            try? err.fileHandleForReading.close()
            throw SpawnError.failed(rc)
        }
        return Child(pid: pid, stdout: out.fileHandleForReading, stderr: err.fileHandleForReading)
    }

    /// Non-blocking: nil while the child runs.
    static func poll(_ child: Child) -> Exit? {
        var status: Int32 = 0
        let r = waitpid(child.pid, &status, WNOHANG)
        if r == 0 { return nil }
        if r < 0 { return Exit(status: -1, signaled: false) }
        return exit(status)
    }

    static func wait(_ child: Child) -> Exit {
        var status: Int32 = 0
        while waitpid(child.pid, &status, 0) < 0 {
            if errno != EINTR { return Exit(status: -1, signaled: false) }
        }
        return exit(status)
    }

    static func terminate(_ child: Child) { kill(child.pid, SIGTERM) }

    private static func exit(_ status: Int32) -> Exit {
        // WIFSIGNALED / WEXITSTATUS by hand (the macros aren't imported).
        let low = status & 0x7f
        if low == 0 { return Exit(status: (status >> 8) & 0xff, signaled: false) }
        return Exit(status: low, signaled: true)
    }

    /// NULL-terminated array of copies, as execve wants; the bytes are the strings' UTF-8, untouched.
    private static func cStrings(_ strings: [String]) -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> {
        let array = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: strings.count + 1)
        for (i, s) in strings.enumerated() { array[i] = s.withCString { strdup($0) } }
        array[strings.count] = nil
        return array
    }

    /// Frees what `cStrings` made.
    private static func free(_ array: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) {
        var i = 0
        while let p = array[i] { Darwin.free(p); i += 1 }
        array.deallocate()
    }
}
