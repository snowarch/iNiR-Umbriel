pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    readonly property string socketPath: {
        const explicitSocket = Quickshell.env("UMBRIEL_SOCKET") ?? ""
        if (explicitSocket.length > 0)
            return explicitSocket
        const runtimeDir = Quickshell.env("XDG_RUNTIME_DIR") ?? ""
        const display = Quickshell.env("WAYLAND_DISPLAY") ?? ""
        return runtimeDir.length > 0 && display.length > 0
            ? `${runtimeDir}/umbriel-${display}.sock` : ""
    }
    readonly property bool available: socketPath.length > 0

    property var windows: []
    property var workspaces: []
    property var activeWindow: null
    property var mruWindowIds: []
    property string currentOutput: ""
    property bool inOverview: false
    property var keyboardLayoutNames: []
    property int currentKeyboardLayoutIndex: 0
    property var surfaceStates: ({})
    readonly property var currentOutputWorkspaces: workspaces.filter(workspace => workspace.output === currentOutput)

    signal windowOrderChanged()

    DankSocket {
        id: eventStreamSocket
        path: root.socketPath
        connected: CompositorService.isUmbriel && root.available

        onConnectionStateChanged: {
            if (CompositorService.isUmbriel && root.available) {
                send({
                    cmd: "subscribe",
                    events: ["windows", "workspaces", "overview", "keyboard_layout"]
                })
            }
        }

        parser: SplitParser {
            onRead: line => root.handleEvent(line)
        }
    }

    Component {
        id: stateQuerySocketComponent

        Socket {
            id: stateQuerySocket
            required property string payload
            property bool sent: false

            path: root.socketPath
            connected: true

            onConnectionStateChanged: {
                if (connected && !sent) {
                    sent = true
                    write(payload + "\n")
                    flush()
                } else if (!connected && sent) {
                    Qt.callLater(() => stateQuerySocket.destroy())
                }
            }

            parser: SplitParser {
                onRead: line => {
                    try {
                        const reply = JSON.parse(line)
                        if (reply?.ok)
                            root.setSurfaceState(reply.ok)
                        else if (reply?.err)
                            console.warn("UmbrielService:", reply.err)
                    } catch (e) {
                        console.warn("UmbrielService: invalid state reply:", line)
                    }
                    stateQuerySocket.connected = false
                }
            }
        }
    }

    Timer {
        interval: 750
        running: CompositorService.isUmbriel && root.available && root.windows.length > 0
        repeat: true
        triggeredOnStart: true
        onTriggered: root.querySurfaceState()
    }

    Component {
        id: requestSocketComponent

        Socket {
            id: requestSocket
            required property string payload
            property bool sent: false

            path: root.socketPath
            connected: true

            onConnectionStateChanged: {
                if (connected && !sent) {
                    sent = true
                    write(payload + "\n")
                    flush()
                } else if (!connected && sent) {
                    Qt.callLater(() => requestSocket.destroy())
                }
            }

            parser: SplitParser {
                onRead: line => {
                    try {
                        const reply = JSON.parse(line)
                        if (reply?.err)
                            console.warn("UmbrielService:", reply.err)
                    } catch (e) {
                        console.warn("UmbrielService: invalid IPC reply:", line)
                    }
                    requestSocket.connected = false
                }
            }
        }
    }

    function handleEvent(line: string): void {
        try {
            const message = JSON.parse(line)
            switch (message.event) {
            case "windows":
                setWindows(message.data)
                break
            case "workspaces":
                setWorkspaces(message.data)
                break
            case "overview":
                root.inOverview = message.data?.open === true
                break
            case "keyboard_layout":
                root.keyboardLayoutNames = Array.isArray(message.data?.names) ? message.data.names : []
                root.currentKeyboardLayoutIndex = Number(message.data?.current_index ?? 0)
                break
            }
        } catch (e) {
            console.warn("UmbrielService: failed to parse event:", line, e)
        }
    }

    function setWindows(data): void {
        if (!Array.isArray(data))
            return
        const nextWindows = data.map(window => ({
            id: String(window.id ?? ""),
            workspaceId: String(window.workspace ?? ""),
            appId: String(window.app_id ?? ""),
            title: String(window.title ?? ""),
            focused: window.focused === true,
            active: window.active === true,
            floating: window.floating === true,
            minimized: false,
            urgent: window.urgent === true,
            xwayland: window.xwayland === true,
            fullscreen: root.surfaceStates[String(window.id ?? "")]?.fullscreen === true,
            output: String(root.surfaceStates[String(window.id ?? "")]?.output ?? ""),
            tearingEligible: root.surfaceStates[String(window.id ?? "")]?.eligible === true,
            tearingHint: String(root.surfaceStates[String(window.id ?? "")]?.hint ?? ""),
            x: Number(window.x ?? 0),
            y: Number(window.y ?? 0),
            width: Number(window.w ?? 0),
            height: Number(window.h ?? 0)
        }))
        root.windows = nextWindows
        root.activeWindow = nextWindows.find(window => window.focused) ?? null
        const liveIds = new Set(nextWindows.map(window => window.id))
        let nextMru = root.mruWindowIds.filter(id => liveIds.has(String(id))).map(id => String(id))
        const focusedId = root.activeWindow?.id ?? ""
        if (focusedId.length > 0) {
            nextMru = nextMru.filter(id => id !== focusedId)
            nextMru.unshift(focusedId)
        }
        for (const window of nextWindows) {
            if (!nextMru.includes(window.id))
                nextMru.push(window.id)
        }
        root.mruWindowIds = nextMru
        root.windowOrderChanged()
    }

    function setSurfaceState(data): void {
        const surfaces = Array.isArray(data?.surfaces) ? data.surfaces : []
        const next = ({})
        for (const surface of surfaces) {
            const id = String(surface.id ?? "")
            if (id.length === 0)
                continue
            next[id] = {
                fullscreen: surface.fullscreen === true,
                output: String(surface.output ?? ""),
                eligible: surface.eligible === true,
                hint: String(surface.hint ?? ""),
                ruleOverride: surface.rule_override ?? null
            }
        }
        root.surfaceStates = next
        root.windows = root.windows.map(window => Object.assign({}, window, {
            fullscreen: next[window.id]?.fullscreen === true,
            output: String(next[window.id]?.output ?? ""),
            tearingEligible: next[window.id]?.eligible === true,
            tearingHint: String(next[window.id]?.hint ?? "")
        }))
        root.activeWindow = root.windows.find(window => window.focused) ?? null
    }

    function querySurfaceState(): bool {
        if (!root.available)
            return false
        return stateQuerySocketComponent.createObject(root, {
            payload: JSON.stringify({ cmd: "tearing" })
        }) !== null
    }

    function setWorkspaces(data): void {
        if (!Array.isArray(data))
            return
        root.workspaces = data.map(workspace => ({
            id: String(workspace.id ?? ""),
            name: String(workspace.name ?? ""),
            index: Number(workspace.index ?? 0),
            output: String(workspace.output ?? ""),
            active: workspace.active === true,
            focused: workspace.focused === true,
            layout: String(workspace.layout ?? "")
        }))
        const focused = root.workspaces.find(workspace => workspace.focused)
            ?? root.workspaces.find(workspace => workspace.active)
        root.currentOutput = focused?.output ?? ""
    }

    function request(command): bool {
        if (!root.available)
            return false
        const socket = requestSocketComponent.createObject(root, {
            payload: JSON.stringify(command)
        })
        return socket !== null
    }

    function sendAction(action: string): bool {
        return request({ cmd: "msg", arg: action })
    }

    function focusWindow(windowId): bool {
        return sendAction(`window-focus:${windowId}`)
    }

    function closeWindow(windowId): bool {
        return sendAction(`window-close:${windowId}`)
    }

    function switchWorkspace(workspace): bool {
        if (!workspace)
            return false
        const selector = workspace.name?.length > 0 ? workspace.name : String(workspace.index)
        const qualified = workspace.output?.length > 0 ? `${selector}/${workspace.output}` : selector
        return sendAction(`workspace-switch:${qualified}`)
    }

    function toggleOverview(): bool {
        return sendAction("overview-toggle")
    }

    function focusWorkspaceUp(): bool {
        return sendAction("workspace-previous")
    }

    function focusWorkspaceDown(): bool {
        return sendAction("workspace-next")
    }

    function quitSession(): bool {
        return sendAction("session-quit")
    }

    function powerOffMonitors(): bool {
        return sendAction("dpms-off")
    }

    function powerOnMonitors(): bool {
        return sendAction("dpms-on")
    }
}
