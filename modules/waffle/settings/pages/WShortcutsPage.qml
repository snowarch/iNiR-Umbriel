pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.services
import qs.services.deferred
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.waffle.looks
import qs.modules.waffle.settings

WSettingsPage {
    id: root
    settingsPageIndex: 9
    pageTitle: Translation.tr("Shortcuts")
    pageIcon: "keyboard"
    pageDescription: Translation.tr("Keyboard shortcuts from compositor config")

    readonly property var keybindBackend: CompositorService.isUmbriel ? UmbrielKeybinds
        : CompositorService.isNiri ? NiriKeybinds : null
    readonly property var keybinds: keybindBackend?.keybinds ?? null
    readonly property var categories: keybinds?.children ?? []

    property var keySubstitutions: ({
        "Super": "󰖳", "Slash": "/", "Return": "↵", "Escape": "Esc",
        "Comma": ",", "Period": ".", "BracketLeft": "[", "BracketRight": "]",
        "Left": "←", "Right": "→", "Up": "↑", "Down": "↓",
        "Page_Up": "PgUp", "Page_Down": "PgDn", "Home": "Home", "End": "End"
    })

    // Status card
    WSettingsCard {
        visible: root.keybindBackend !== null

        RowLayout {
            Layout.fillWidth: true
            spacing: 12

            FluentIcon {
                icon: (root.keybindBackend?.loaded ?? false) ? "checkmark" : "info"
                implicitSize: 20
                color: (root.keybindBackend?.loaded ?? false) ? Looks.colors.accent : Looks.colors.subfg
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2

                WText {
                    text: (root.keybindBackend?.loaded ?? false)
                        ? Translation.tr("Keybinds loaded from config")
                        : Translation.tr("Using default keybinds")
                    font.pixelSize: Looks.font.pixelSize.normal
                }

                WText {
                    visible: (root.keybindBackend?.loaded ?? false)
                    text: (root.keybindBackend?.configPath ?? "")
                    font.pixelSize: Looks.font.pixelSize.small
                    color: Looks.colors.subfg
                    elide: Text.ElideMiddle
                    Layout.fillWidth: true
                }
            }
        }
    }

    WSettingsInfoBar {
        visible: root.keybindBackend === null
        severity: WSettingsInfoBar.Severity.Warning
        message: Translation.tr("Shortcuts are unavailable for this compositor.")
    }

    // Categories
    Repeater {
        model: root.categories

        delegate: WSettingsCard {
            id: categoryCard
            required property var modelData
            required property int index

            readonly property var categoryKeybinds: modelData.children?.[0]?.keybinds ?? []

            title: root.displayCategoryName(modelData.name)
            icon: root.getCategoryIcon(modelData.name)

            // Register each keybind for search
            Repeater {
                model: categoryCard.categoryKeybinds

                delegate: WKeybindRow {
                    required property var modelData
                    required property int index

                    Layout.fillWidth: true
                    mods: modelData.mods ?? []
                    keyName: modelData.key ?? ""
                    action: modelData.comment ?? ""
                    showDivider: index < categoryCard.categoryKeybinds.length - 1
                    keySubstitutions: root.keySubstitutions

                    // Search registration
                    settingsPageIndex: root.settingsPageIndex
                    settingsPageName: root.pageTitle
                    settingsSection: root.displayCategoryName(categoryCard.modelData.name)
                }
            }
        }
    }

    function displayCategoryName(name: string): string {
        if (name === "ii Shell")
            return Translation.tr("iNiR Shell")
        return name
    }

    function getCategoryIcon(name: string): string {
        const icons = {
            "System": "power",
            "ii Shell": "wand",
            "iNiR Shell": "wand",
            "Window Switcher": "arrow-sync",
            "Screenshots": "screenshot",
            "Applications": "apps",
            "Window Management": "desktop",
            "Windows": "desktop",
            "Focus": "arrow-enter-left",
            "Move Windows": "arrow-right",
            "Workspaces": "apps",
            "Media": "speaker-2-filled",
            "Brightness": "weather-sunny",
            "Outputs": "desktop",
            "Media & Hardware": "speaker-2-filled",
            "Other": "options"
        }
        return icons[name] ?? "keyboard"
    }
}
