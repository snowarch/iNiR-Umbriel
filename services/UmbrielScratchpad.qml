pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.services

Singleton {
    id: root

    readonly property bool actionReady: UmbrielService.available && String(Quickshell.env("UMBRIEL_SOCKET") ?? "").length > 0
    readonly property var windows: (UmbrielService.windows ?? []).filter(window => window.workspaceId === "")

    property var outputByWindow: ({})
    property var previousWorkspaceByWindow: ({})
    property var stashOrder: []

    property string pendingRestoreId: ""
    property string pendingRestoreOutput: ""
    property bool pendingRestoreOpenedScratchpad: false
    property string pendingRestorePhase: ""

    function workspaceOutput(workspaceId): string {
        const id = String(workspaceId ?? "")
        if (id.length === 0) return ""
        return String((UmbrielService.workspaces ?? []).find(workspace => workspace.id === id)?.output ?? "")
    }

    function knownOutputs(): var {
        const outputs = []
        for (const workspace of UmbrielService.workspaces ?? []) {
            const name = String(workspace.output ?? "")
            if (name.length > 0 && !outputs.includes(name)) outputs.push(name)
        }
        return outputs
    }

    function outputForWindow(windowId): string {
        const id = String(windowId ?? "")
        const known = String(root.outputByWindow[id] ?? "")
        if (known.length > 0) return known
        const outputs = root.knownOutputs()
        if (outputs.length === 1) return outputs[0]
        return ""
    }

    function isScratchpadWindow(windowId): bool {
        const id = String(windowId ?? "")
        return root.windows.some(window => window.id === id)
    }

    function idsForApp(appId): var {
        const needle = String(appId ?? "").toLowerCase()
        if (needle.length === 0) return []
        return root.windows
            .filter(window => String(window.appId ?? "").toLowerCase() === needle)
            .map(window => window.id)
    }

    function countForApp(appId): int {
        return root.idsForApp(appId).length
    }

    function idsForOutput(outputName): var {
        const output = String(outputName ?? "")
        return root.windows
            .filter(window => root.outputForWindow(window.id) === output)
            .map(window => window.id)
    }

    function latestId(ids): string {
        const candidates = new Set((ids ?? []).map(id => String(id)))
        for (let i = root.stashOrder.length - 1; i >= 0; --i) {
            const id = String(root.stashOrder[i])
            if (candidates.has(id)) return id
        }
        return ids?.length > 0 ? String(ids[ids.length - 1]) : ""
    }

    function actionForOutput(action: string, outputName: string): string {
        const output = String(outputName ?? "")
        return output.length > 0 ? `${action}:${output}` : action
    }

    function moveWindow(windowId = ""): bool {
        if (!root.actionReady) return false
        const active = UmbrielService.activeWindow
        const requested = String(windowId ?? "")
        if (!active?.id || active.workspaceId === "") return false
        if (requested.length > 0 && String(active.id) !== requested) return false

        const output = root.workspaceOutput(active.workspaceId) || UmbrielService.currentOutput
        if (output.length === 0) return false
        root.outputByWindow = Object.assign({}, root.outputByWindow, { [active.id]: output })
        return UmbrielService.sendAction(root.actionForOutput("window-move-to-scratchpad", output))
    }

    function toggle(outputName = ""): bool {
        if (!root.actionReady) return false
        const output = String(outputName ?? "") || UmbrielService.currentOutput
        return UmbrielService.sendAction(root.actionForOutput("scratchpad-toggle", output))
    }

    function focusNext(outputName = ""): bool {
        if (!root.actionReady) return false
        const output = String(outputName ?? "") || UmbrielService.currentOutput
        return UmbrielService.sendAction(root.actionForOutput("scratchpad-focus-next", output))
    }

    function restoreFocused(outputName = ""): bool {
        if (!root.actionReady) return false
        const output = String(outputName ?? "") || UmbrielService.currentOutput
        return UmbrielService.sendAction(root.actionForOutput("window-restore-from-scratchpad", output))
    }

    function restoreWindow(windowId): bool {
        if (!root.actionReady || root.pendingRestoreId.length > 0) return false
        const id = String(windowId ?? "")
        const target = root.windows.find(window => window.id === id)
        if (!target) return false
        const output = root.outputForWindow(id)
        if (output.length === 0) return false

        root.pendingRestoreId = id
        root.pendingRestoreOutput = output
        root.pendingRestoreOpenedScratchpad = false
        root.pendingRestorePhase = "focus"
        if (!UmbrielService.focusWindow(id)) {
            root.clearPendingRestore()
            return false
        }
        restoreDelay.restart()
        return true
    }

    function restoreLatestForApp(appId): bool {
        const id = root.latestId(root.idsForApp(appId))
        return id.length > 0 ? root.restoreWindow(id) : false
    }

    function restoreLatest(outputName = ""): bool {
        const output = String(outputName ?? "")
        const ids = output.length > 0 ? root.idsForOutput(output) : root.windows.map(window => window.id)
        const id = root.latestId(ids)
        return id.length > 0 ? root.restoreWindow(id) : false
    }

    function clearPendingRestore(): void {
        root.pendingRestoreId = ""
        root.pendingRestoreOutput = ""
        root.pendingRestoreOpenedScratchpad = false
        root.pendingRestorePhase = ""
        restoreDelay.stop()
        verifyRestoreDelay.stop()
        showFallbackDelay.stop()
    }

    function syncWindows(): void {
        const current = UmbrielService.windows ?? []
        const liveIds = new Set(current.map(window => String(window.id)))
        const nextOutputs = Object.assign({}, root.outputByWindow)
        const nextPrevious = ({})
        let nextOrder = root.stashOrder.filter(id => liveIds.has(String(id)))

        for (const window of current) {
            const id = String(window.id)
            const workspaceId = String(window.workspaceId ?? "")
            const previousWorkspace = String(root.previousWorkspaceByWindow[id] ?? "")
            if (workspaceId === "" && previousWorkspace.length > 0) {
                const output = root.workspaceOutput(previousWorkspace)
                if (output.length > 0) nextOutputs[id] = output
                nextOrder = nextOrder.filter(entry => String(entry) !== id)
                nextOrder.push(id)
            } else if (workspaceId !== "") {
                delete nextOutputs[id]
                nextOrder = nextOrder.filter(entry => String(entry) !== id)
            }
            nextPrevious[id] = workspaceId
        }

        for (const id in nextOutputs) {
            if (!liveIds.has(String(id))) delete nextOutputs[id]
        }
        root.outputByWindow = nextOutputs
        root.previousWorkspaceByWindow = nextPrevious
        root.stashOrder = nextOrder

        if (root.pendingRestoreId.length === 0) return
        const target = current.find(window => String(window.id) === root.pendingRestoreId)
        if (!target) {
            root.clearPendingRestore()
            return
        }

        if (String(target.workspaceId ?? "").length > 0) {
            const openedScratchpad = root.pendingRestoreOpenedScratchpad
            const output = root.pendingRestoreOutput
            root.clearPendingRestore()
            if (openedScratchpad && root.idsForOutput(output).length > 0)
                Qt.callLater(() => root.toggle(output))
        }
    }

    Timer {
        id: restoreDelay
        interval: 80
        repeat: false
        onTriggered: {
            if (root.pendingRestoreId.length === 0 || root.pendingRestorePhase !== "focus") return
            root.pendingRestorePhase = "restore"
            if (!root.restoreFocused(root.pendingRestoreOutput)) {
                root.clearPendingRestore()
                return
            }
            verifyRestoreDelay.restart()
        }
    }

    Timer {
        id: verifyRestoreDelay
        interval: 180
        repeat: false
        onTriggered: {
            if (root.pendingRestoreId.length === 0) return
            const target = (UmbrielService.windows ?? []).find(window => window.id === root.pendingRestoreId)
            if (!target || String(target.workspaceId ?? "").length > 0) {
                root.syncWindows()
                return
            }
            if (root.pendingRestoreOpenedScratchpad) {
                root.clearPendingRestore()
                return
            }
            root.pendingRestoreOpenedScratchpad = true
            root.pendingRestorePhase = "show"
            if (!root.toggle(root.pendingRestoreOutput)) {
                root.clearPendingRestore()
                return
            }
            showFallbackDelay.restart()
        }
    }

    Timer {
        id: showFallbackDelay
        interval: 140
        repeat: false
        onTriggered: {
            if (root.pendingRestoreId.length === 0 || root.pendingRestorePhase !== "show") return
            root.pendingRestorePhase = "focus"
            if (!UmbrielService.focusWindow(root.pendingRestoreId)) {
                root.clearPendingRestore()
                return
            }
            restoreDelay.restart()
        }
    }

    Connections {
        target: UmbrielService
        function onWindowsChanged() { root.syncWindows() }
    }

    Component.onCompleted: root.syncWindows()

    IpcHandler {
        target: "scratchpad"
        function status(): string {
            return JSON.stringify(root.windows.map(window => ({
                id: window.id,
                appId: window.appId,
                title: window.title,
                output: root.outputForWindow(window.id)
            })))
        }
        function toggle(): void { root.toggle() }
        function moveFocused(): void { root.moveWindow() }
        function restore(windowId: string): void { root.restoreWindow(windowId) }
        function restoreLatest(): void { root.restoreLatest() }
        function focusNext(): void { root.focusNext() }
    }
}
