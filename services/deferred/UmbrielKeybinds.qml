pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.modules.common.functions

Singleton {
    id: root

    property var keybinds: ({ children: [] })
    property var allBinds: []
    property var enrichedCategories: []
    property bool loaded: false
    property string configPath: ""
    property string errorMessage: ""
    property string _pendingSetCombo: ""
    property string _pendingRemoveCombo: ""

    signal bindSaved(string keyCombo)
    signal bindRemoved(string keyCombo)
    signal bindError(string message)

    readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME")
        ?? (Quickshell.env("HOME") + "/.config")
    readonly property string userConfigPath: configHome + "/umbriel/config.toml"
    readonly property string bindsPath: configHome + "/umbriel/config.d/70-binds.toml"
    readonly property string configScript: FileUtils.trimFileProtocol(
        Qt.resolvedUrl("../../scripts/umbriel-config.py"))

    function reload(): void {
        loader.running = true
    }

    function setBind(keyCombo: string, action: string, options: string): void {
        if (setBindProcess.running)
            return
        root._pendingSetCombo = keyCombo
        const args = ["/usr/bin/python3", root.configScript, "--config", root.userConfigPath,
            "set-bind", keyCombo, action]
        if (options && options.length > 0)
            args.push("--options", options)
        setBindProcess.command = args
        setBindProcess.running = true
    }

    function removeBind(keyCombo: string): void {
        if (removeBindProcess.running)
            return
        root._pendingRemoveCombo = keyCombo
        removeBindProcess.command = ["/usr/bin/python3", root.configScript, "--config",
            root.userConfigPath, "remove-bind", keyCombo]
        removeBindProcess.running = true
    }

    function applyResult(output: string): void {
        try {
            const result = JSON.parse(output)
            root.allBinds = result.binds ?? []
            root.enrichedCategories = result.categories ?? []
            root.keybinds = ({ children: result.children ?? [] })
            root.configPath = result.configPath ?? root.userConfigPath
            root.loaded = true
            root.errorMessage = ""
        } catch (e) {
            root.loaded = false
            root.errorMessage = "Failed to parse Umbriel keybinds"
        }
    }

    Process {
        id: loader
        command: ["/usr/bin/python3", root.configScript, "--config", root.userConfigPath, "get-binds"]
        stdout: StdioCollector { id: loadCollector }
        onExited: exitCode => {
            const output = loadCollector.text?.trim() ?? ""
            if (exitCode === 0 && output.length > 0)
                root.applyResult(output)
            else {
                root.loaded = false
                root.errorMessage = "Umbriel keybind parser failed"
            }
        }
    }

    Process {
        id: setBindProcess
        running: false
        stdout: StdioCollector { id: setCollector }
        onExited: exitCode => {
            const combo = root._pendingSetCombo
            root._pendingSetCombo = ""
            if (exitCode === 0) {
                root.reload()
                root.bindSaved(combo)
            } else {
                root.errorMessage = setCollector.text?.trim() || "Failed to save Umbriel keybind"
                root.bindError(root.errorMessage)
            }
        }
    }

    Process {
        id: removeBindProcess
        running: false
        stdout: StdioCollector { id: removeCollector }
        onExited: exitCode => {
            const combo = root._pendingRemoveCombo
            root._pendingRemoveCombo = ""
            if (exitCode === 0) {
                root.reload()
                root.bindRemoved(combo)
            } else {
                root.errorMessage = removeCollector.text?.trim() || "Failed to remove Umbriel keybind"
                root.bindError(root.errorMessage)
            }
        }
    }

    FileView {
        path: root.userConfigPath
        watchChanges: true
        onFileChanged: reloadDebounce.restart()
    }

    FileView {
        path: root.bindsPath
        watchChanges: true
        onFileChanged: reloadDebounce.restart()
    }

    Timer {
        id: reloadDebounce
        interval: 300
        repeat: false
        onTriggered: root.reload()
    }

    Component.onCompleted: root.reload()
}
