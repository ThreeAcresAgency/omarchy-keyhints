import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Ui

// One keybinding worth learning right now, plus a popup with the bigger
// picture. keyhints.py picks the hint from the usage log (written by
// ~/.config/hypr/keyhints.lua) and the current Hyprland context; this file
// only displays it and relays clicks back.
//   left   = open the usage popup
//   middle = next suggestion
//   right  = open the full keybindings menu
//   scroll = step suggestions back and forth
Panel {
  id: root
  moduleName: "brendan.keyhints"
  ipcTarget: "brendan.keyhints"

  readonly property bool vertical: bar ? bar.vertical : false
  readonly property int barSize: bar ? bar.barSize : Style.bar.sizeHorizontal
  // The script lives next to this file, wherever the plugin was installed.
  readonly property string script: Qt.resolvedUrl("keyhints.py").toString().replace(/^file:\/\//, "")
  readonly property int maxLabelWidth: Number(setting("maxWidth", 360))

  property string hintId: ""
  property string hintKeys: ""
  property string hintDesc: ""
  property string reason: ""
  property int hintUses: 0
  property int learnedCount: 0
  property int totalCount: 0
  property int presses: 0
  property var upNext: []
  property var mostUsed: []
  property bool trackerInstalled: true
  property bool refreshPending: false

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string tooltip: reason
    ? reason + "  ·  learned " + learnedCount + " of " + totalCount
      + "\nclick = usage  ·  middle/scroll = next  ·  right = all keybindings"
    : ""

  function refresh() {
    if (panelProc.running) {
      refreshPending = true
      return
    }
    refreshPending = false
    panelProc.running = true
  }

  function act(command) {
    var cmd = [root.script, command]
    if (command === "learned" || command === "snooze") {
      if (!root.hintId) return
      cmd.push(root.hintId)
    }
    actionProc.command = cmd
    actionProc.running = true
  }

  function openKeybindings() {
    root.close()
    if (root.bar) root.bar.run("omarchy-menu-keybindings")
  }

  Component.onCompleted: refresh()

  // Window open/close, focus and workspace changes all shift the context.
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (!event || !event.name) return
      var name = String(event.name)
      if (name === "openwindow" || name === "closewindow" || name === "workspace"
          || name === "activewindow" || name === "changefloatingmode"
          || name === "focusedmon" || name === "movewindow" || name === "configreloaded") {
        debounce.restart()
      }
    }
  }

  // A keypress landing in the log may retire the hint being shown, and the
  // script edits state.json from the terminal too.
  FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/keyhints/usage.log"
    watchChanges: true
    onFileChanged: debounce.restart()
  }

  FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/keyhints/state.json"
    watchChanges: true
    onFileChanged: debounce.restart()
  }

  Timer {
    id: debounce
    interval: 300
    onTriggered: root.refresh()
  }

  // Rotation is time-based inside the script; poll so the label follows it.
  Timer {
    interval: 60000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Process {
    id: panelProc
    command: [root.script, "panel"]
    onRunningChanged: if (!running && root.refreshPending) root.refresh()
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var data
        try {
          data = JSON.parse(String(text || "").trim() || "{}")
        } catch (e) {
          return
        }
        var hint = data.hint || {}
        root.hintId = hint.id || ""
        root.hintKeys = hint.keys || ""
        root.hintDesc = hint.desc || ""
        root.reason = hint.reason || ""
        root.hintUses = hint.uses || 0
        root.learnedCount = data.learned || 0
        root.totalCount = data.total || 0
        root.presses = data.presses || 0
        root.upNext = data.up_next || []
        root.mostUsed = data.most_used || []
        root.trackerInstalled = data.tracker !== false
      }
    }
  }

  Process {
    id: actionProc
    onExited: root.refresh()
  }

  visible: hintId !== "" && !vertical
  implicitWidth: visible ? Math.min(maxLabelWidth, row.implicitWidth) + Style.spacing.controlPaddingX * 2 : 0
  implicitHeight: barSize

  Behavior on implicitWidth {
    NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
  }

  Item {
    id: label
    anchors.fill: parent
    anchors.leftMargin: Style.space(8)
    anchors.rightMargin: Style.space(8)
    clip: true

    Row {
      id: row
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(6)

      Text {
        textFormat: Text.PlainText
        text: root.hintKeys
        color: root.bar ? root.bar.barForeground : Color.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
      }

      Text {
        textFormat: Text.PlainText
        text: "→  " + root.hintDesc
        color: root.bar ? root.bar.barForeground : Color.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        opacity: 0.75
      }
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
    cursorShape: Qt.PointingHandCursor

    onClicked: function(mouse) {
      if (mouse.button === Qt.RightButton) root.openKeybindings()
      else if (mouse.button === Qt.MiddleButton) root.act("next")
      else root.toggle()
    }
    onWheel: function(wheel) {
      if (wheel.angleDelta.y < 0) root.act("next")
      else if (wheel.angleDelta.y > 0) root.act("prev")
    }
    onEntered: if (root.bar) root.bar.showTooltip(root, root.tooltip)
    onExited: if (root.bar) root.bar.hideTooltip(root)
  }

  KeyboardPanel {
    id: panel
    anchorItem: label
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (dx > 0 || dy > 0) root.act("next")
        else if (dx < 0 || dy < 0) root.act("prev")
      }
      onActivateRequested: root.act("learned")
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- Hero: the current suggestion ----------
        Column {
          width: parent.width
          spacing: Style.space(4)

          Text {
            textFormat: Text.PlainText
            text: root.hintKeys
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
            font.bold: true
            elide: Text.ElideRight
            width: parent.width
          }

          Text {
            textFormat: Text.PlainText
            text: root.hintDesc
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            elide: Text.ElideRight
            width: parent.width
          }

          Text {
            textFormat: Text.PlainText
            text: (root.reason + "  ·  used " + root.hintUses + "×").toUpperCase()
            color: Qt.darker(root.fg, 1.4)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1.2
            elide: Text.ElideRight
            width: parent.width
          }
        }

        Row {
          id: actionRow
          width: parent.width
          spacing: Style.space(6)
          readonly property real cellWidth: (width - spacing * 2) / 3

          Button {
            width: actionRow.cellWidth
            iconText: ""
            text: "Got it"
            fontSize: Style.font.bodySmall
            foreground: root.fg
            fontFamily: root.fontFamily
            bordered: true
            onClicked: root.act("learned")
          }
          Button {
            width: actionRow.cellWidth
            iconText: ""
            text: "Later"
            fontSize: Style.font.bodySmall
            foreground: root.fg
            fontFamily: root.fontFamily
            bordered: true
            onClicked: root.act("snooze")
          }
          Button {
            width: actionRow.cellWidth
            iconText: ""
            text: "Next"
            fontSize: Style.font.bodySmall
            foreground: root.fg
            fontFamily: root.fontFamily
            bordered: true
            onClicked: root.act("next")
          }
        }

        // ---------- Up next ----------
        PanelSeparator { foreground: root.fg }

        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: root.upNext.length > 0

          PanelSectionHeader {
            text: "UP NEXT"
            foreground: root.fg
            fontFamily: root.fontFamily
          }

          Repeater {
            model: root.upNext
            BindingRow {
              required property var modelData
              keys: modelData.keys || ""
              desc: modelData.desc || ""
            }
          }
        }

        // ---------- Most used ----------
        PanelSeparator { foreground: root.fg }

        Column {
          width: parent.width
          spacing: Style.space(6)

          PanelSectionHeader {
            text: "MOST USED"
            foreground: root.fg
            fontFamily: root.fontFamily
          }

          Text {
            visible: root.mostUsed.length === 0
            textFormat: Text.PlainText
            text: "No keybinding presses logged yet."
            color: root.fg
            opacity: 0.6
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Repeater {
            model: root.mostUsed
            BindingRow {
              required property var modelData
              keys: modelData.keys || ""
              desc: modelData.desc || ""
              count: modelData.uses || 0
              dim: modelData.learned === true
            }
          }
        }

        // ---------- Footer ----------
        PanelSeparator { foreground: root.fg }

        Text {
          visible: !root.trackerInstalled
          width: parent.width
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          text: "Usage tracker not installed, so hints only rotate on a timer. Run install-tracker.sh from the plugin folder."
          color: root.fg
          opacity: 0.8
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Item {
          width: parent.width
          implicitHeight: Math.max(summary.implicitHeight, allButton.implicitHeight)

          Text {
            id: summary
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "Learned " + root.learnedCount + " of " + root.totalCount + "  ·  " + root.presses + " presses"
            color: root.fg
            opacity: 0.6
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Button {
            id: allButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            iconText: ""
            text: "All keybindings"
            fontSize: Style.font.bodySmall
            foreground: root.fg
            fontFamily: root.fontFamily
            bordered: true
            onClicked: root.openKeybindings()
          }
        }
      }
    }
  }

  component BindingRow: Item {
    property string keys: ""
    property string desc: ""
    property int count: -1
    property bool dim: false

    width: parent.width
    implicitHeight: Math.max(keysText.implicitHeight, descText.implicitHeight)
    opacity: dim ? 0.45 : 1

    Text {
      id: keysText
      textFormat: Text.PlainText
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(170)
      text: keys
      color: root.fg
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
      elide: Text.ElideRight
    }

    Text {
      id: descText
      textFormat: Text.PlainText
      anchors.left: keysText.right
      anchors.leftMargin: Style.space(8)
      anchors.right: countText.visible ? countText.left : parent.right
      anchors.rightMargin: countText.visible ? Style.space(8) : 0
      anchors.verticalCenter: parent.verticalCenter
      text: desc
      color: root.fg
      opacity: 0.8
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }

    Text {
      id: countText
      visible: count >= 0
      textFormat: Text.PlainText
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: count + "×"
      color: root.fg
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }
}
