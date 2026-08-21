import Foundation

/// Exactly one Blurt may run at a time.
///
/// This is load-bearing for recovery, not just tidiness: because a live
/// instance holds this lock for its whole life, any recording still sitting in
/// `inflight/` when we successfully acquire the lock is definitionally
/// abandoned — no timestamps or heuristics needed. A frozen instance keeps the
/// lock until it is killed, at which point the kernel releases it for us.
final class SingleInstanceGuard {

    private var fd: Int32 = -1

    /// Takes the lock. Returns false if another instance already holds it.
    func acquire() -> Bool {
        AppPaths.ensure()
        let path = AppPaths.lockFile.path
        fd = open(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else {
            Log.error("Could not open lock file: \(String(cString: strerror(errno)))")
            return true  // Never refuse to start over a lock we cannot even create.
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            fd = -1
            return false
        }
        // Leave the owning pid behind for debugging.
        ftruncate(fd, 0)
        let pid = "\(ProcessInfo.processInfo.processIdentifier)\n"
        _ = pid.withCString { write(fd, $0, strlen($0)) }
        return true
    }

    func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    deinit { release() }
}
