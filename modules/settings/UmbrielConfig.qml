import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.services
import qs.modules.common
import qs.modules.common.widgets

ContentPage {
    id: root
    settingsPageIndex: 12
    settingsPageName: Translation.tr("Compositor")

    property string activeSection: "general"
    property var configData: ({})
    property var outputList: []
    property bool loaded: false
    property bool managed: false
    property bool controlsReady: false
    property string configPath: ""
    property string errorMessage: ""
    property string infoMessage: ""
    property var setQueue: []
    property string pendingPath: ""
    property bool outputPreviewPending: false
    property int outputPreviewSeconds: 0
    property string outputPreviewLabel: ""

    readonly property string helperPath: Quickshell.shellPath("scripts/umbriel-config.py")
    readonly property bool canEdit: root.loaded && root.managed

    function configValue(path, fallback) {
        const parts = path.split(".")
        let value = root.configData
        for (const part of parts) {
            if (value === null || value === undefined || typeof value !== "object" || !(part in value))
                return fallback
            value = value[part]
        }
        return value
    }

    function outputIdentity(output) {
        const configName = String(output?.config_name ?? "").trim()
        return configName.length > 0 ? configName : String(output?.name ?? "")
    }

    function outputConfig(output) {
        const outputs = root.configData?.output ?? ({})
        const configName = String(output?.config_name ?? "")
        const connector = String(output?.name ?? "")
        if (configName.length > 0 && outputs[configName] !== undefined)
            return outputs[configName]
        return outputs[connector] ?? ({})
    }

    function outputConfigValue(output, key, fallback) {
        const config = root.outputConfig(output)
        return config[key] !== undefined ? config[key] : fallback
    }

    function modeValue(mode) {
        if (!mode) return ""
        const hz = Number(mode.refresh_mhz ?? 0) / 1000
        let rate = hz.toFixed(3).replace(/0+$/, "").replace(/\.$/, "")
        return `${mode.width}x${mode.height}@${rate}`
    }

    function modeOptions(output) {
        const seen = new Set()
        const result = []
        for (const mode of output?.modes ?? []) {
            const value = root.modeValue(mode)
            if (!value || seen.has(value)) continue
            seen.add(value)
            result.push({
                displayName: `${mode.width}×${mode.height} @ ${(Number(mode.refresh_mhz ?? 0) / 1000).toFixed(2)} Hz${mode.preferred ? " · Preferred" : ""}`,
                value: value
            })
        }
        return result
    }

    function scaleOptions(output) {
        const values = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
        const current = Number(output?.scale ?? 1)
        if (!values.some(value => Math.abs(value - current) < 0.001)) values.push(current)
        values.sort((a, b) => a - b)
        return values.map(value => ({ displayName: `${Math.round(value * 100)}%`, value: value }))
    }

    function choiceIndex(model, value) {
        const index = (model ?? []).findIndex(option => String(option.value) === String(value))
        return Math.max(0, index)
    }

    function previewOutput(output, key, value) {
        if (!root.canEdit || outputPreviewProcess.running || confirmOutputPreviewProcess.running || revertOutputPreviewProcess.running)
            return
        const identity = root.outputIdentity(output)
        if (identity.length === 0) return
        root.outputPreviewLabel = `${output?.name ?? identity} · ${key}`
        outputPreviewProcess.command = ["python3", root.helperPath, "preview-output", identity, key, JSON.stringify(value)]
        outputPreviewProcess.running = true
    }

    function confirmOutputPreview() {
        if (!root.outputPreviewPending || confirmOutputPreviewProcess.running) return
        confirmOutputPreviewProcess.running = true
    }

    function revertOutputPreview() {
        if (!root.outputPreviewPending || revertOutputPreviewProcess.running) return
        revertOutputPreviewProcess.running = true
    }

    function refreshConfig() {
        if (!configProcess.running)
            configProcess.running = true
    }

    function refreshOutputs() {
        if (!outputsProcess.running)
            outputsProcess.running = true
    }

    function queueSet(path, value) {
        if (!root.controlsReady || !root.canEdit)
            return
        const next = root.setQueue.filter(entry => entry.path !== path)
        next.push({ path: path, value: value })
        root.setQueue = next
        root.runNextSet()
    }

    function runNextSet() {
        if (setProcess.running || root.setQueue.length === 0)
            return
        const next = root.setQueue.slice()
        const request = next.shift()
        root.setQueue = next
        root.pendingPath = request.path
        setProcess.command = ["python3", root.helperPath, "set", request.path, JSON.stringify(request.value)]
        setProcess.running = true
    }

    function parseResult(text, fallbackMessage) {
        try {
            return JSON.parse(text || "{}")
        } catch (e) {
            root.errorMessage = fallbackMessage
            return null
        }
    }

    Component.onCompleted: {
        root.refreshConfig()
        root.refreshOutputs()
    }

    Process {
        id: configProcess
        command: ["python3", root.helperPath, "get-config"]
        stdout: StdioCollector {
            id: configCollector
            onStreamFinished: {
                const data = root.parseResult(configCollector.text, Translation.tr("Unable to parse Umbriel configuration."))
                if (!data)
                    return
                if (data.success !== true) {
                    root.errorMessage = data.error ?? Translation.tr("Unable to read Umbriel configuration.")
                    return
                }
                root.controlsReady = false
                root.configData = data.config ?? ({})
                root.configPath = data.configPath ?? ""
                root.managed = data.managed ?? false
                root.loaded = true
                root.errorMessage = ""
                Qt.callLater(() => root.controlsReady = true)
            }
        }
        stderr: StdioCollector { id: configErrorCollector }
        onExited: exitCode => {
            if (exitCode !== 0)
                root.errorMessage = (configErrorCollector.text || configCollector.text || Translation.tr("Unable to read Umbriel configuration.")).trim()
        }
    }

    Process {
        id: outputsProcess
        command: ["python3", root.helperPath, "outputs"]
        stdout: StdioCollector {
            id: outputsCollector
            onStreamFinished: {
                const data = root.parseResult(outputsCollector.text, Translation.tr("Unable to parse Umbriel outputs."))
                if (data?.success === true)
                    root.outputList = data.outputs ?? []
            }
        }
        stderr: StdioCollector { id: outputsErrorCollector }
        onExited: exitCode => {
            if (exitCode !== 0)
                root.errorMessage = (outputsErrorCollector.text || outputsCollector.text || Translation.tr("Unable to query Umbriel outputs.")).trim()
        }
    }

    Process {
        id: setProcess
        stdout: StdioCollector { id: setCollector }
        stderr: StdioCollector { id: setErrorCollector }
        onExited: exitCode => {
            const data = root.parseResult(setCollector.text, Translation.tr("Unable to parse Umbriel update result."))
            if (exitCode !== 0 || data?.success !== true) {
                root.errorMessage = data?.error ?? (setErrorCollector.text || setCollector.text || Translation.tr("Umbriel rejected the configuration change.")).trim()
            } else {
                root.errorMessage = ""
                root.infoMessage = Translation.tr("Umbriel configuration updated live.")
            }
            root.pendingPath = ""
            root.refreshConfig()
            root.runNextSet()
        }
    }

    Process {
        id: outputPreviewProcess
        stdout: StdioCollector { id: outputPreviewCollector }
        stderr: StdioCollector { id: outputPreviewErrorCollector }
        onExited: exitCode => {
            const data = root.parseResult(outputPreviewCollector.text, Translation.tr("Unable to parse output preview result."))
            if (exitCode !== 0 || data?.success !== true) {
                root.errorMessage = data?.error ?? (outputPreviewErrorCollector.text || outputPreviewCollector.text || Translation.tr("Umbriel rejected the output preview.")).trim()
                return
            }
            root.errorMessage = ""
            root.infoMessage = Translation.tr("Output preview active. Confirm it before the automatic rollback.")
            root.outputPreviewPending = true
            root.outputPreviewSeconds = Number(data.timeout ?? 15) + 1
            outputPreviewCountdown.restart()
            root.refreshConfig()
            root.refreshOutputs()
        }
    }

    Process {
        id: confirmOutputPreviewProcess
        command: ["python3", root.helperPath, "confirm-output-preview"]
        stdout: StdioCollector { id: confirmOutputPreviewCollector }
        stderr: StdioCollector { id: confirmOutputPreviewErrorCollector }
        onExited: exitCode => {
            const data = root.parseResult(confirmOutputPreviewCollector.text, Translation.tr("Unable to parse output confirmation result."))
            if (exitCode !== 0 || data?.success !== true) {
                root.errorMessage = data?.error ?? (confirmOutputPreviewErrorCollector.text || confirmOutputPreviewCollector.text || Translation.tr("Unable to confirm the output preview.")).trim()
                return
            }
            outputPreviewCountdown.stop()
            root.outputPreviewPending = false
            root.outputPreviewSeconds = 0
            root.infoMessage = Translation.tr("Output configuration confirmed.")
            root.refreshConfig()
            root.refreshOutputs()
        }
    }

    Process {
        id: revertOutputPreviewProcess
        command: ["python3", root.helperPath, "revert-output-preview"]
        stdout: StdioCollector { id: revertOutputPreviewCollector }
        stderr: StdioCollector { id: revertOutputPreviewErrorCollector }
        onExited: exitCode => {
            const data = root.parseResult(revertOutputPreviewCollector.text, Translation.tr("Unable to parse output rollback result."))
            if (exitCode !== 0 || data?.success !== true) {
                root.errorMessage = data?.error ?? (revertOutputPreviewErrorCollector.text || revertOutputPreviewCollector.text || Translation.tr("Unable to revert the output preview.")).trim()
                return
            }
            outputPreviewCountdown.stop()
            root.outputPreviewPending = false
            root.outputPreviewSeconds = 0
            root.infoMessage = Translation.tr("Output preview reverted.")
            root.refreshConfig()
            root.refreshOutputs()
        }
    }

    Timer {
        id: outputPreviewCountdown
        interval: 1000
        repeat: true
        onTriggered: {
            root.outputPreviewSeconds = Math.max(0, root.outputPreviewSeconds - 1)
            if (root.outputPreviewSeconds === 0) {
                stop()
                root.outputPreviewPending = false
                root.infoMessage = Translation.tr("Output preview rollback completed.")
                root.refreshConfig()
                root.refreshOutputs()
            }
        }
    }

    SettingsTaskNavigator {
        icon: "desktop_windows"
        title: Translation.tr("Umbriel")
        description: Translation.tr("Edit only settings Umbriel owns natively. Changes are validated and reloaded without restarting the compositor.")
        summary: Translation.tr("General · Input · Layout · Appearance · Scratchpad · Animations · Displays")
        currentValue: root.activeSection
        onSelected: value => root.activeSection = value
        options: [
            { displayName: Translation.tr("General"), icon: "tune", value: "general" },
            { displayName: Translation.tr("Input"), icon: "keyboard", value: "input" },
            { displayName: Translation.tr("Layout"), icon: "view_column", value: "layout" },
            { displayName: Translation.tr("Appearance"), icon: "style", value: "appearance" },
            { displayName: Translation.tr("Scratchpad"), icon: "inventory_2", value: "scratchpad" },
            { displayName: Translation.tr("Animations"), icon: "animation", value: "animations" },
            { displayName: Translation.tr("Displays"), icon: "monitor", value: "displays" }
        ]
    }

    SettingsCardSection {
        visible: root.errorMessage.length > 0 || root.infoMessage.length > 0 || !root.managed
        expanded: true
        icon: root.errorMessage.length > 0 ? "error" : root.managed ? "check_circle" : "info"
        title: root.errorMessage.length > 0 ? Translation.tr("Umbriel configuration error") : Translation.tr("Umbriel configuration")

        SettingsGroup {
            StyledText {
                Layout.fillWidth: true
                text: root.errorMessage.length > 0 ? root.errorMessage
                    : !root.managed
                        ? Translation.tr("This config is not using iNiR's managed config.d layout. iNiR will show values but will not rewrite an arbitrary custom file.")
                        : root.infoMessage
                wrapMode: Text.WordWrap
                color: root.errorMessage.length > 0 ? Appearance.colors.colError : Appearance.colors.colSubtext
                font.pixelSize: Appearance.font.pixelSize.small
            }
            StyledText {
                Layout.fillWidth: true
                visible: root.configPath.length > 0
                text: root.configPath
                color: Appearance.colors.colSubtext
                font.family: Appearance.font.family.monospace
                font.pixelSize: Appearance.font.pixelSize.smallest
                wrapMode: Text.WrapAnywhere
            }
        }
    }

    SettingsCardSection {
        settingsTaskSection: "general"
        visible: root.activeSection === "general"
        expanded: true
        icon: "tune"
        title: Translation.tr("Session & overview")

        SettingsGroup {
            SettingsSwitch {
                buttonIcon: "desktop_windows"
                text: Translation.tr("Enable XWayland")
                checked: root.configValue("general.xwayland", true)
                onCheckedChanged: root.queueSet("general.xwayland", checked)
            }
            SettingsSwitch {
                buttonIcon: "ads_click"
                text: Translation.tr("Honor application activation requests")
                checked: root.configValue("general.focus_on_activate", false)
                onCheckedChanged: root.queueSet("general.focus_on_activate", checked)
            }
            ConfigSpinBox {
                icon: "zoom_out_map"
                text: Translation.tr("Overview zoom (%)")
                value: Math.round(root.configValue("overview.zoom", 0.75) * 100)
                from: 40
                to: 100
                stepSize: 5
                onValueChanged: root.queueSet("overview.zoom", value / 100)
            }
            SettingsSwitch {
                buttonIcon: "keyboard"
                text: Translation.tr("Overview shortcuts")
                checked: root.configValue("overview.shortcuts", true)
                onCheckedChanged: root.queueSet("overview.shortcuts", checked)
            }
            SettingsSwitch {
                buttonIcon: "south_west"
                text: Translation.tr("Top-left overview hot corner")
                checked: root.configValue("hot_corners.top_left.enabled", true)
                onCheckedChanged: root.queueSet("hot_corners.top_left.enabled", checked)
            }
            ConfigSpinBox {
                visible: root.configValue("hot_corners.top_left.enabled", true)
                icon: "timer"
                text: Translation.tr("Hot corner delay (ms)")
                value: root.configValue("hot_corners.top_left.delay_ms", 500)
                from: 0
                to: 2000
                stepSize: 50
                onValueChanged: root.queueSet("hot_corners.top_left.delay_ms", value)
            }
        }
    }

    SettingsCardSection {
        settingsTaskSection: "input"
        visible: root.activeSection === "input"
        expanded: true
        icon: "keyboard"
        title: Translation.tr("Input")

        SettingsGroup {
            ContentSubsection {
                title: Translation.tr("Keyboard layout")
                MaterialTextField {
                    Layout.fillWidth: true
                    text: String(root.configValue("input.keyboard.layout", "us"))
                    placeholderText: "us, es, de…"
                    onEditingFinished: {
                        const next = text.trim()
                        if (next.length > 0 && next !== root.configValue("input.keyboard.layout", "us"))
                            root.queueSet("input.keyboard.layout", next)
                    }
                }
            }
            ConfigSelectionArray {
                currentValue: root.configValue("input.keyboard.track_layout", "global")
                options: [
                    { displayName: Translation.tr("Global layout"), icon: "public", value: "global" },
                    { displayName: Translation.tr("Per-window layout"), icon: "select_window", value: "window" }
                ]
                onSelected: value => root.queueSet("input.keyboard.track_layout", value)
            }
            SettingsSwitch {
                buttonIcon: "dialpad"
                text: Translation.tr("NumLock on keyboard connect")
                checked: root.configValue("input.keyboard.numlock_toggle", false)
                onCheckedChanged: root.queueSet("input.keyboard.numlock_toggle", checked)
            }
            ConfigSpinBox {
                icon: "timer"
                text: Translation.tr("Key repeat delay (ms)")
                value: root.configValue("input.keyboard.repeat_delay", 250)
                from: 100
                to: 1000
                stepSize: 25
                onValueChanged: root.queueSet("input.keyboard.repeat_delay", value)
            }
            ConfigSpinBox {
                icon: "speed"
                text: Translation.tr("Key repeat rate")
                value: root.configValue("input.keyboard.repeat_rate", 50)
                from: 10
                to: 100
                stepSize: 5
                onValueChanged: root.queueSet("input.keyboard.repeat_rate", value)
            }
            SettingsSwitch {
                buttonIcon: "touch_app"
                text: Translation.tr("Touchpad tap to click")
                checked: root.configValue("input.touchpad.tap", true)
                onCheckedChanged: root.queueSet("input.touchpad.tap", checked)
            }
            ConfigSelectionArray {
                currentValue: root.configValue("input.mouse.accel_profile", "flat")
                options: [
                    { displayName: Translation.tr("Flat mouse acceleration"), icon: "straighten", value: "flat" },
                    { displayName: Translation.tr("Adaptive mouse acceleration"), icon: "speed", value: "adaptive" }
                ]
                onSelected: value => root.queueSet("input.mouse.accel_profile", value)
            }
            SettingsSwitch {
                buttonIcon: "center_focus_strong"
                text: Translation.tr("Focus follows mouse")
                checked: root.configValue("input.focus.follows_mouse", false)
                onCheckedChanged: root.queueSet("input.focus.follows_mouse", checked)
            }
            ContentSubsection {
                title: Translation.tr("Cursor theme")
                Item {
                    Layout.fillWidth: true
                    implicitHeight: cursorThemeField.implicitHeight

                    MaterialTextField {
                        id: cursorThemeField
                        anchors.left: parent.left
                        anchors.right: parent.right
                        text: String(root.configValue("input.cursor.theme", "capitaine-cursors-light"))
                        onEditingFinished: {
                            const next = text.trim()
                            if (next.length > 0 && next !== root.configValue("input.cursor.theme", ""))
                                root.queueSet("input.cursor.theme", next)
                        }
                    }
                }
            }
            ConfigSpinBox {
                icon: "mouse"
                text: Translation.tr("Cursor size")
                value: root.configValue("input.cursor.size", 24)
                from: 16
                to: 96
                stepSize: 2
                onValueChanged: root.queueSet("input.cursor.size", value)
            }
            SettingsSwitch {
                buttonIcon: "keyboard_hide"
                text: Translation.tr("Hide cursor while typing")
                checked: root.configValue("input.cursor.hide_when_typing", true)
                onCheckedChanged: root.queueSet("input.cursor.hide_when_typing", checked)
            }
        }
    }

    SettingsCardSection {
        settingsTaskSection: "layout"
        visible: root.activeSection === "layout"
        expanded: true
        icon: "view_column"
        title: Translation.tr("Layout")

        SettingsGroup {
            ConfigSelectionArray {
                currentValue: root.configValue("layout.mode", "scrolling")
                options: [
                    { displayName: Translation.tr("Scrolling"), icon: "view_column", value: "scrolling" },
                    { displayName: Translation.tr("Dwindle"), icon: "grid_view", value: "dwindle" },
                    { displayName: Translation.tr("Master"), icon: "dashboard", value: "master" }
                ]
                onSelected: value => root.queueSet("layout.mode", value)
            }
            ConfigSpinBox {
                icon: "padding"
                text: Translation.tr("Window gap")
                value: root.configValue("layout.gap", 25)
                from: 0
                to: 64
                stepSize: 1
                onValueChanged: root.queueSet("layout.gap", value)
            }
            ConfigSelectionArray {
                visible: root.configValue("layout.mode", "scrolling") === "scrolling"
                currentValue: root.configValue("layout.scrolling.direction", "horizontal")
                options: [
                    { displayName: Translation.tr("Horizontal scrolling"), icon: "swap_horiz", value: "horizontal" },
                    { displayName: Translation.tr("Vertical scrolling"), icon: "swap_vert", value: "vertical" }
                ]
                onSelected: value => root.queueSet("layout.scrolling.direction", value)
            }
            ConfigSpinBox {
                visible: root.configValue("layout.mode", "scrolling") === "scrolling"
                icon: "width"
                text: Translation.tr("Default strip size (%)")
                value: Math.round(root.configValue("layout.scrolling.default_width_fraction", 0.5) * 100)
                from: 10
                to: 100
                stepSize: 5
                onValueChanged: root.queueSet("layout.scrolling.default_width_fraction", value / 100)
                StyledToolTip {
                    text: Translation.tr("On horizontal workspaces this is the initial column width. On vertical workspaces it is the initial lane height.")
                }
            }
            SettingsSwitch {
                visible: root.configValue("layout.mode", "scrolling") === "scrolling"
                buttonIcon: "align_horizontal_center"
                text: Translation.tr("Center underfull strip")
                checked: root.configValue("layout.scrolling.center_underfull_strip", true)
                onCheckedChanged: root.queueSet("layout.scrolling.center_underfull_strip", checked)
            }
            SettingsSwitch {
                visible: root.configValue("layout.mode", "scrolling") === "scrolling"
                buttonIcon: "center_focus_strong"
                text: Translation.tr("Always center focused strip item")
                checked: root.configValue("layout.scrolling.center_focused", false)
                onCheckedChanged: root.queueSet("layout.scrolling.center_focused", checked)
            }
            SettingsSwitch {
                visible: root.configValue("layout.mode", "scrolling") === "scrolling"
                buttonIcon: "fullscreen"
                text: Translation.tr("Expand a single strip item")
                checked: root.configValue("layout.scrolling.expand_single_column", false)
                onCheckedChanged: root.queueSet("layout.scrolling.expand_single_column", checked)
            }

            SettingsSwitch {
                visible: root.configValue("layout.mode", "scrolling") === "dwindle"
                buttonIcon: "account_tree"
                text: Translation.tr("Preserve split directions")
                checked: root.configValue("layout.dwindle.preserve_split", false)
                onCheckedChanged: root.queueSet("layout.dwindle.preserve_split", checked)
                StyledToolTip {
                    text: Translation.tr("Keep each Dwindle split direction fixed after it is created instead of reflowing it with the tile geometry.")
                }
            }

            ConfigSelectionArray {
                visible: root.configValue("layout.mode", "scrolling") === "master"
                currentValue: root.configValue("layout.master.position", "left")
                options: [
                    { displayName: Translation.tr("Master on left"), icon: "align_horizontal_left", value: "left" },
                    { displayName: Translation.tr("Master on right"), icon: "align_horizontal_right", value: "right" }
                ]
                onSelected: value => root.queueSet("layout.master.position", value)
            }
            ConfigSpinBox {
                visible: root.configValue("layout.mode", "scrolling") === "master"
                icon: "width"
                text: Translation.tr("Initial master width (%)")
                value: Math.round(root.configValue("layout.master.default_width_fraction", 0.55) * 100)
                from: 10
                to: 90
                stepSize: 5
                onValueChanged: root.queueSet("layout.master.default_width_fraction", value / 100)
            }
            SettingsSwitch {
                visible: root.configValue("layout.mode", "scrolling") === "master"
                buttonIcon: "vertical_align_top"
                text: Translation.tr("New stack windows on top")
                checked: root.configValue("layout.master.new_on_top", true)
                onCheckedChanged: root.queueSet("layout.master.new_on_top", checked)
            }
        }
    }

    SettingsCardSection {
        settingsTaskSection: "appearance"
        visible: root.activeSection === "appearance"
        expanded: true
        icon: "style"
        title: Translation.tr("Window appearance")

        SettingsGroup {
            SettingsSwitch {
                buttonIcon: "web_asset_off"
                text: Translation.tr("Prefer server-side decorations")
                checked: root.configValue("appearance.prefer_no_csd", true)
                onCheckedChanged: root.queueSet("appearance.prefer_no_csd", checked)
            }
            ConfigSpinBox {
                icon: "rounded_corner"
                text: Translation.tr("Corner radius")
                value: root.configValue("appearance.corner_radius", 16)
                from: 0
                to: 48
                stepSize: 1
                onValueChanged: root.queueSet("appearance.corner_radius", value)
            }
            ConfigSpinBox {
                icon: "border_style"
                text: Translation.tr("Border width")
                value: root.configValue("appearance.border_width", 0)
                from: 0
                to: 12
                stepSize: 1
                onValueChanged: root.queueSet("appearance.border_width", value)
            }
            ConfigSpinBox {
                icon: "select_all"
                text: Translation.tr("Outer border width")
                value: root.configValue("appearance.outer_border_width", 0)
                from: 0
                to: 12
                stepSize: 1
                onValueChanged: root.queueSet("appearance.outer_border_width", value)
            }
            SettingsSwitch {
                buttonIcon: "filter_none"
                text: Translation.tr("Window shadows")
                checked: root.configValue("appearance.shadow.enabled", true)
                onCheckedChanged: root.queueSet("appearance.shadow.enabled", checked)
            }
            ConfigSpinBox {
                visible: root.configValue("appearance.shadow.enabled", true)
                icon: "blur_on"
                text: Translation.tr("Shadow softness")
                value: root.configValue("appearance.shadow.softness", 30)
                from: 0
                to: 100
                stepSize: 2
                onValueChanged: root.queueSet("appearance.shadow.softness", value)
            }
            ConfigSpinBox {
                visible: root.configValue("appearance.shadow.enabled", true)
                icon: "swap_horiz"
                text: Translation.tr("Shadow X offset")
                value: root.configValue("appearance.shadow.offset_x", 0)
                from: -50
                to: 50
                stepSize: 1
                onValueChanged: root.queueSet("appearance.shadow.offset_x", value)
            }
            ConfigSpinBox {
                visible: root.configValue("appearance.shadow.enabled", true)
                icon: "swap_vert"
                text: Translation.tr("Shadow Y offset")
                value: root.configValue("appearance.shadow.offset_y", 5)
                from: -50
                to: 50
                stepSize: 1
                onValueChanged: root.queueSet("appearance.shadow.offset_y", value)
            }
            ContentSubsection {
                title: Translation.tr("Native blur engine")

                SettingsSwitch {
                    buttonIcon: "blur_on"
                    text: Translation.tr("Enable Umbriel blur")
                    checked: root.configValue("appearance.blur.enabled", false)
                    onCheckedChanged: root.queueSet("appearance.blur.enabled", checked)
                }
                SettingsSwitch {
                    enabled: root.configValue("appearance.blur.enabled", false)
                    buttonIcon: "memory"
                    text: Translation.tr("Optimized blur cache")
                    checked: root.configValue("appearance.blur.optimized", true)
                    onCheckedChanged: root.queueSet("appearance.blur.optimized", checked)
                }
                ConfigSpinBox {
                    enabled: root.configValue("appearance.blur.enabled", false)
                    icon: "filter_blur"
                    text: Translation.tr("Blur passes")
                    value: root.configValue("appearance.blur.passes", 3)
                    from: 0
                    to: 8
                    stepSize: 1
                    onValueChanged: root.queueSet("appearance.blur.passes", value)
                }
                ConfigSpinBox {
                    enabled: root.configValue("appearance.blur.enabled", false)
                    icon: "blur_medium"
                    text: Translation.tr("Blur radius")
                    value: root.configValue("appearance.blur.radius", 5)
                    from: 0
                    to: 100
                    stepSize: 1
                    onValueChanged: root.queueSet("appearance.blur.radius", value)
                }
            }
            StyledText {
                Layout.fillWidth: true
                text: Translation.tr("This is Umbriel's own scene blur engine. iNiR does not request Niri's ext-background-effect protocol in an Umbriel session.")
                color: Appearance.colors.colSubtext
                font.pixelSize: Appearance.font.pixelSize.smaller
                wrapMode: Text.WordWrap
            }
        }
    }

    SettingsCardSection {
        settingsTaskSection: "scratchpad"
        visible: root.activeSection === "scratchpad"
        expanded: true
        icon: "inventory_2"
        title: Translation.tr("Native scratchpad")

        SettingsGroup {
            StyledText {
                Layout.fillWidth: true
                text: Translation.tr("Umbriel scratchpads are compositor-owned holding areas, one per output. They are not hidden workspaces: Umbriel preserves the source workspace and restores it natively.")
                color: Appearance.colors.colSubtext
                font.pixelSize: Appearance.font.pixelSize.small
                wrapMode: Text.WordWrap
            }
            SettingsSwitch {
                buttonIcon: "animation"
                text: Translation.tr("Animate scratchpad")
                checked: root.configValue("animation.scratchpad.enabled", true)
                onCheckedChanged: root.queueSet("animation.scratchpad.enabled", checked)
            }
            ConfigSpinBox {
                icon: "timer"
                text: Translation.tr("Scratchpad duration (ms)")
                value: root.configValue("animation.scratchpad.duration_ms", 200)
                from: 50
                to: 1000
                stepSize: 25
                onValueChanged: root.queueSet("animation.scratchpad.duration_ms", value)
            }
            ConfigSpinBox {
                icon: "contrast"
                text: Translation.tr("Backdrop dim (%)")
                value: Math.round(root.configValue("animation.scratchpad.dim", 0.35) * 100)
                from: 0
                to: 100
                stepSize: 5
                onValueChanged: root.queueSet("animation.scratchpad.dim", value / 100)
            }
            SettingsSwitch {
                buttonIcon: "blur_on"
                text: Translation.tr("Blur scratchpad backdrop")
                enabled: root.configValue("appearance.blur.enabled", false)
                checked: root.configValue("animation.scratchpad.blur", false)
                onCheckedChanged: root.queueSet("animation.scratchpad.blur", checked)
                StyledToolTip {
                    text: root.configValue("appearance.blur.enabled", false)
                        ? Translation.tr("Use Umbriel's native blur behind the visible scratchpad")
                        : Translation.tr("Enable Umbriel blur in Appearance first")
                }
            }
            ConfigSpinBox {
                icon: "zoom_out_map"
                text: Translation.tr("Entry scale (%)")
                value: Math.round(root.configValue("animation.scratchpad.scale", 0.0) * 100)
                from: 0
                to: 100
                stepSize: 5
                onValueChanged: root.queueSet("animation.scratchpad.scale", value / 100)
                StyledToolTip {
                    text: Translation.tr("0% preserves the window geometry. Higher values size and center the window when it enters the scratchpad.")
                }
            }
            SettingsSwitch {
                buttonIcon: "open_in_full"
                text: Translation.tr("Maximize on entry")
                checked: root.configValue("animation.scratchpad.maximize", false)
                onCheckedChanged: root.queueSet("animation.scratchpad.maximize", checked)
            }
            SettingsSwitch {
                buttonIcon: "fullscreen"
                text: Translation.tr("Fullscreen on entry")
                checked: root.configValue("animation.scratchpad.fullscreen", false)
                onCheckedChanged: root.queueSet("animation.scratchpad.fullscreen", checked)
            }
            StyledText {
                Layout.fillWidth: true
                text: Translation.tr("Default shortcuts: Super+Shift+Space moves the focused window into the scratchpad or restores the focused scratchpad window. Super+Alt+Space shows or hides the current output's scratchpad.")
                color: Appearance.colors.colSubtext
                font.pixelSize: Appearance.font.pixelSize.smaller
                wrapMode: Text.WordWrap
            }
        }
    }

    SettingsCardSection {
        settingsTaskSection: "animations"
        visible: root.activeSection === "animations"
        expanded: true
        icon: "animation"
        title: Translation.tr("Animations")

        SettingsGroup {
            SettingsSwitch {
                buttonIcon: "animation"
                text: Translation.tr("Enable compositor animations")
                checked: root.configValue("animation.enabled", true)
                onCheckedChanged: root.queueSet("animation.enabled", checked)
            }
            ConfigSpinBox {
                visible: root.configValue("animation.enabled", true)
                icon: "timer"
                text: Translation.tr("Default duration (ms)")
                value: root.configValue("animation.duration_ms", 250)
                from: 50
                to: 1000
                stepSize: 25
                onValueChanged: root.queueSet("animation.duration_ms", value)
            }
            Repeater {
                model: [
                    { key: "windows_in", label: Translation.tr("Window open") },
                    { key: "windows_out", label: Translation.tr("Window close") },
                    { key: "windows_move", label: Translation.tr("Window movement") },
                    { key: "workspaces", label: Translation.tr("Workspaces") },
                    { key: "overview", label: Translation.tr("Overview") }
                ]
                delegate: SettingsSwitch {
                    required property var modelData
                    buttonIcon: "motion_photos_on"
                    text: modelData.label
                    checked: root.configValue(`animation.${modelData.key}.enabled`, true)
                    onCheckedChanged: root.queueSet(`animation.${modelData.key}.enabled`, checked)
                }
            }
        }
    }

    SettingsCardSection {
        settingsTaskSection: "displays"
        visible: root.activeSection === "displays"
        expanded: true
        icon: "monitor"
        title: Translation.tr("Displays")

        SettingsGroup {
            StyledText {
                Layout.fillWidth: true
                text: Translation.tr("Mode, scale, rotation, VRR, tearing, direct scanout and HDR use Umbriel's native output configuration. Every change starts as a 15-second preview backed by an external systemd rollback, so it still reverts if iNiR crashes or the new mode makes the shell unusable.")
                color: Appearance.colors.colSubtext
                font.pixelSize: Appearance.font.pixelSize.small
                wrapMode: Text.WordWrap
            }

            SettingsNote {
                visible: root.outputPreviewPending
                warning: true
                icon: "timer"
                text: Translation.tr("Preview: %1 · automatic rollback in ~%2 s").arg(root.outputPreviewLabel).arg(root.outputPreviewSeconds)
            }

            RowLayout {
                Layout.fillWidth: true
                visible: root.outputPreviewPending
                spacing: 8

                RippleButton {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 38
                    buttonText: Translation.tr("Keep changes")
                    toggled: true
                    onClicked: root.confirmOutputPreview()
                }
                RippleButton {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 38
                    buttonText: Translation.tr("Revert now")
                    onClicked: root.revertOutputPreview()
                }
            }

            Repeater {
                model: root.outputList
                delegate: ColumnLayout {
                    id: outputDelegate
                    required property var modelData
                    Layout.fillWidth: true
                    spacing: 6
                    readonly property var currentMode: (modelData.modes ?? []).find(mode => mode.current) ?? ({})
                    readonly property var modes: root.modeOptions(modelData)
                    readonly property var scales: root.scaleOptions(modelData)
                    readonly property var transforms: [
                        { displayName: Translation.tr("Normal"), value: "normal" },
                        { displayName: "90°", value: "90" },
                        { displayName: "180°", value: "180" },
                        { displayName: "270°", value: "270" },
                        { displayName: Translation.tr("Flipped"), value: "flipped" },
                        { displayName: Translation.tr("Flipped 90°"), value: "flipped-90" },
                        { displayName: Translation.tr("Flipped 180°"), value: "flipped-180" },
                        { displayName: Translation.tr("Flipped 270°"), value: "flipped-270" }
                    ]
                    readonly property var vrrModes: [
                        { displayName: Translation.tr("Disabled"), value: "disabled" },
                        { displayName: Translation.tr("Always"), value: "always" },
                        { displayName: Translation.tr("Fullscreen only"), value: "fullscreen" }
                    ]
                    readonly property var hdrModes: [
                        { displayName: Translation.tr("Off"), value: "off" },
                        { displayName: Translation.tr("On"), value: "on" },
                        { displayName: Translation.tr("Automatic"), value: "auto" },
                        { displayName: Translation.tr("Fullscreen"), value: "fullscreen" }
                    ]

                    SettingsDivider {}
                    StyledText {
                        Layout.fillWidth: true
                        text: modelData.description ?? modelData.name ?? Translation.tr("Display")
                        color: Appearance.colors.colOnLayer1
                        font.pixelSize: Appearance.font.pixelSize.normal
                        font.weight: Font.Medium
                        wrapMode: Text.WordWrap
                    }
                    StyledText {
                        Layout.fillWidth: true
                        text: `${modelData.name ?? ""} · ${currentMode.width ?? "?"}×${currentMode.height ?? "?"} @ ${((currentMode.refresh_mhz ?? 0) / 1000).toFixed(2)} Hz · ${Math.round(Number(modelData.scale ?? 1) * 100)}%`
                        color: Appearance.colors.colSubtext
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        font.family: Appearance.font.family.monospace
                        wrapMode: Text.WordWrap
                    }

                    ContentSubsection {
                        title: Translation.tr("Mode")
                        StyledComboBox {
                            Layout.fillWidth: true
                            enabled: root.canEdit && !outputPreviewProcess.running
                            model: outputDelegate.modes
                            textRole: "displayName"
                            currentIndex: root.choiceIndex(model, root.modeValue(outputDelegate.currentMode))
                            onActivated: {
                                const choice = model[currentIndex]
                                if (choice && choice.value !== root.modeValue(outputDelegate.currentMode))
                                    root.previewOutput(outputDelegate.modelData, "mode", choice.value)
                            }
                        }
                    }

                    ContentSubsection {
                        title: Translation.tr("Scale")
                        StyledComboBox {
                            Layout.fillWidth: true
                            enabled: root.canEdit && !outputPreviewProcess.running
                            model: outputDelegate.scales
                            textRole: "displayName"
                            currentIndex: root.choiceIndex(model, Number(outputDelegate.modelData.scale ?? 1))
                            onActivated: {
                                const choice = model[currentIndex]
                                if (choice && Math.abs(Number(choice.value) - Number(outputDelegate.modelData.scale ?? 1)) > 0.001)
                                    root.previewOutput(outputDelegate.modelData, "scale", Number(choice.value))
                            }
                        }
                    }

                    ContentSubsection {
                        title: Translation.tr("Rotation")
                        StyledComboBox {
                            Layout.fillWidth: true
                            enabled: root.canEdit && !outputPreviewProcess.running
                            model: outputDelegate.transforms
                            textRole: "displayName"
                            currentIndex: root.choiceIndex(model, outputDelegate.modelData.transform ?? "normal")
                            onActivated: {
                                const choice = model[currentIndex]
                                if (choice && choice.value !== (outputDelegate.modelData.transform ?? "normal"))
                                    root.previewOutput(outputDelegate.modelData, "transform", choice.value)
                            }
                        }
                    }

                    ContentSubsection {
                        title: Translation.tr("Variable refresh rate")
                        tooltip: Translation.tr("Umbriel policies are disabled, always-on, or fullscreen-only.")
                        StyledComboBox {
                            Layout.fillWidth: true
                            enabled: root.canEdit && !outputPreviewProcess.running
                            model: outputDelegate.vrrModes
                            textRole: "displayName"
                            currentIndex: root.choiceIndex(model, root.outputConfigValue(outputDelegate.modelData, "vrr", "disabled"))
                            onActivated: {
                                const choice = model[currentIndex]
                                if (choice && choice.value !== root.outputConfigValue(outputDelegate.modelData, "vrr", "disabled"))
                                    root.previewOutput(outputDelegate.modelData, "vrr", choice.value)
                            }
                        }
                    }

                    SettingsSwitch {
                        buttonIcon: "speed"
                        text: Translation.tr("Allow tearing")
                        description: Translation.tr("Lets eligible fullscreen clients request asynchronous presentation. Window rules can still override the client hint.")
                        enabled: root.canEdit && !outputPreviewProcess.running
                        checked: root.outputConfigValue(outputDelegate.modelData, "tearing", false) === true
                        onToggledByUser: checked => root.previewOutput(outputDelegate.modelData, "tearing", checked)
                    }

                    SettingsSwitch {
                        buttonIcon: "bolt"
                        text: Translation.tr("Allow direct scanout")
                        description: Translation.tr("Lets eligible fullscreen buffers bypass composition on this output when Umbriel can do so safely.")
                        enabled: root.canEdit && !outputPreviewProcess.running
                        checked: root.outputConfigValue(outputDelegate.modelData, "direct_scanout", true) === true
                        onToggledByUser: checked => root.previewOutput(outputDelegate.modelData, "direct_scanout", checked)
                    }

                    ContentSubsection {
                        title: Translation.tr("HDR policy")
                        tooltip: Translation.tr("Umbriel can keep HDR off, force it on, follow HDR-capable fullscreen content, or enable it for any fullscreen surface.")
                        StyledComboBox {
                            Layout.fillWidth: true
                            enabled: root.canEdit && !outputPreviewProcess.running
                            model: outputDelegate.hdrModes
                            textRole: "displayName"
                            currentIndex: root.choiceIndex(model, root.outputConfigValue(outputDelegate.modelData, "hdr", "off"))
                            onActivated: {
                                const choice = model[currentIndex]
                                if (choice && choice.value !== root.outputConfigValue(outputDelegate.modelData, "hdr", "off"))
                                    root.previewOutput(outputDelegate.modelData, "hdr", choice.value)
                            }
                        }
                    }
                }
            }
        }
    }
}
