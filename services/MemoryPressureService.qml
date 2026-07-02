pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.modules.common
import qs.services

// Memory pressure monitoring for JSGCHeap accumulation (#164).
// Qt's V4 JS engine creates memfd mappings that persist as "(deleted)" after
// Loader teardown. This service monitors that accumulation and notifies the
// user when a restart would help reclaim memory.
Singleton {
    id: root

    // ── Config ────────────────────────────────────────────────────────────
    readonly property bool enabled: Config.options?.performance?.memoryMonitoring ?? true
    readonly property int deletedMappingsThreshold: Config.options?.performance?.jsgcThreshold ?? 300
    readonly property int checkIntervalMs: 300000  // check every 5 min

    // ── State ─────────────────────────────────────────────────────────────
    property int shellPid: 0
    property int currentDeletedMappings: 0
    property int currentTotalMappings: 0
    property int currentDeletedRssKb: 0
    property bool metricsValid: false
    property bool notificationShown: false
    property bool userDismissed: false

    // ── Public API ────────────────────────────────────────────────────────
    function forceGc(): void {
        gc()
        _log("gc() forced")
    }

    function restart(): void {
        _log("user requested restart")
        Notifications.send(
            "iNiR",
            Translation.tr("Restarting shell..."),
            "system-reboot-symbolic",
            2000, false, {}
        )
        // Small delay so notification shows
        Qt.callLater(() => {
            Quickshell.execDetached(["systemctl", "--user", "restart", "inir.service"])
        })
    }

    function dismiss(): void {
        root.userDismissed = true
        root.notificationShown = false
        _log("user dismissed memory warning")
    }

    function reset(): void {
        root.userDismissed = false
        root.notificationShown = false
        _log("reset state")
    }

    function getStats(): string {
        return JSON.stringify({
            shellPid: root.shellPid,
            metricsValid: root.metricsValid,
            deletedMappings: root.currentDeletedMappings,
            totalMappings: root.currentTotalMappings,
            deletedRssMb: Math.round(root.currentDeletedRssKb / 1024),
            threshold: root.deletedMappingsThreshold,
            notificationShown: root.notificationShown,
            userDismissed: root.userDismissed,
            enabled: root.enabled
        })
    }

    // ── Internal ──────────────────────────────────────────────────────────
    function _log(...args): void {
        if (Quickshell.env("QS_DEBUG") === "1")
            console.log("[MemoryPressure]", ...args)
    }

    function _checkMemoryPressure(): void {
        if (!root.enabled) return
        if (_mapsReader.running) return
        _mapsReader.running = true
    }

    function _notifyUser(): void {
        if (root.notificationShown || root.userDismissed) return

        root.notificationShown = true
        const mbEstimate = root.currentDeletedRssKb > 0
            ? Math.round(root.currentDeletedRssKb / 1024)
            : Math.round(root.currentDeletedMappings * 0.5)  // ~0.5 MB per mapping

        Notifications.send(
            "iNiR",
            Translation.tr("Memory usage is high (~%1 MB accumulated). A restart would free it. Run: inir memory restart").arg(mbEstimate),
            "dialog-warning-symbolic",
            0, false, {}  // persistent until dismissed
        )
        _log("notified user, estimated leak:", mbEstimate, "MB")
    }

    // ── Timers ────────────────────────────────────────────────────────────
    Timer {
        id: _checkTimer
        interval: root.checkIntervalMs
        repeat: true
        running: root.enabled
        onTriggered: root._checkMemoryPressure()
    }

    // ── Maps reader ───────────────────────────────────────────────────────
    // Process children inherit their own /proc/self; Quickshell is $PPID.
    // Validate cmdline before reading maps so a wrong parent never looks like "0 leak".
    Process {
        id: _mapsReader
        command: ["sh", "-c",
            "pid=$PPID; " +
            "cmd=$(tr '\\0' ' ' </proc/$pid/cmdline 2>/dev/null); " +
            "case \"$cmd\" in *qs*inir*) ;; *) pid=0 ;; esac; " +
            "del=0; tot=0; rss=0; " +
            "if [ \"$pid\" -gt 0 ] 2>/dev/null; then " +
            "  del=$(grep -c 'JSGCHeap.*deleted' /proc/$pid/maps 2>/dev/null || echo 0); " +
            "  tot=$(grep -c JSGCHeap /proc/$pid/maps 2>/dev/null || echo 0); " +
            "  rss=$(awk '/^[0-9a-f]+-[0-9a-f]+/ { is_jsgc=($0 ~ /JSGCHeap/); is_del=($0 ~ /\\(deleted\\)/) } " +
            "is_jsgc && is_del && /^Rss:/ { s+=$2 } END { print s+0 }' /proc/$pid/smaps 2>/dev/null || echo 0); " +
            "fi; " +
            "printf '%s\\n%s\\n%s\\n%s\\n' \"$del\" \"$tot\" \"$pid\" \"$rss\""
        ]
        stdout: SplitParser {
            property int lineNum: 0
            onRead: line => {
                const val = parseInt(line.trim()) || 0
                if (lineNum === 0) {
                    root.currentDeletedMappings = val
                } else if (lineNum === 1) {
                    root.currentTotalMappings = val
                } else if (lineNum === 2) {
                    root.shellPid = val
                    root.metricsValid = val > 0
                } else {
                    root.currentDeletedRssKb = val
                }
                lineNum++
            }
        }
        onExited: () => {
            _mapsReader.stdout.lineNum = 0

            if (!root.metricsValid) {
                _log("skipped metrics: shell pid not validated")
                return
            }

            if (root.currentDeletedMappings >= root.deletedMappingsThreshold) {
                _log("threshold exceeded:", root.currentDeletedMappings, ">=", root.deletedMappingsThreshold)
                root._notifyUser()
            }
        }
    }

    // ── IPC ───────────────────────────────────────────────────────────────
    IpcHandler {
        target: "memory"
        function collect(): string { root.forceGc(); return "gc() called" }
        function stats(): string {
            root._checkMemoryPressure()
            return root.getStats()
        }
        function restart(): string { root.restart(); return "restarting..." }
        function dismiss(): string { root.dismiss(); return "dismissed" }
        function reset(): string { root.reset(); return "reset" }
    }

    Component.onCompleted: {
        if (!root.enabled) return
        Qt.callLater(() => {
            _checkTimer.start()
            root._checkMemoryPressure()
        })
    }
}