import Foundation
import Darwin

func peekExit(_ pid: pid_t) -> Int32? {
    var info = siginfo_t()
    let result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
    if result != 0, errno != EINTR { return nil }
    if result == 0, info.si_pid == pid {
        return info.si_code == CLD_EXITED ? info.si_status : 128 + info.si_status
    }
    return nil
}

func processGroupExists(_ pid: pid_t) -> Bool {
    guard pid > 1, pid != getpid() else { return false }
    if kill(-pid, 0) == 0 { return true }
    return errno != ESRCH
}

func stopProcessGroup(_ pid: pid_t, grace: TimeInterval) {
    guard pid > 1, pid != getpid() else { return }
    _ = kill(-pid, SIGTERM)
    if grace > 0 {
        waitUntilGroupStops(pid, until: Date().addingTimeInterval(grace))
    }
    if processGroupExists(pid) {
        _ = kill(-pid, SIGKILL)
        _ = kill(pid, SIGKILL)
        if grace > 0 {
            waitUntilGroupStops(pid, until: Date().addingTimeInterval(grace))
        }
    }
}

private func waitUntilGroupStops(_ pid: pid_t, until deadline: Date) {
    while Date() < deadline, processGroupExists(pid) {
        Thread.sleep(forTimeInterval: 0.02)
    }
}

func reapProcess(_ pid: pid_t) {
    guard pid > 1 else { return }
    var status: Int32 = 0
    let deadline = ProcessInfo.processInfo.systemUptime + 0.2
    while ProcessInfo.processInfo.systemUptime < deadline {
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid || (result < 0 && errno != EINTR) { return }
        Thread.sleep(forTimeInterval: 0.005)
    }
}

// MARK: - Interactive restricted process
