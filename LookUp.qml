// Look Up — a macOS Dictionary-style lookup popup for Omarchy.
//
// Summoned by a hotkey (see the `lookup` script + README). It reads the word
// you have selected, then asks scripts/dict-lookup to consult every dictionary
// listed in config.json, in order, and renders each as its own section — just
// like the source list in macOS Dictionary. Everything is drawn with the
// shell's theme tokens (Color.*/Style.*), so it follows the active Omarchy
// theme automatically. No keyboard focus is stolen from you beyond the popup
// itself, and Escape / click-away / right-click all dismiss it.

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

Item {
  id: root

  // Wired up by the shell host.
  property var shell: null
  property var manifest: null

  property bool opened: false
  property string query: ""
  property bool loading: false
  property var result: emptyResult()

  readonly property string pluginId: (manifest && manifest.id) || "io.github.keegan-sucks.lookup"
  // Absolute path to our query engine, resolved relative to this QML file so it
  // works no matter where the plugin is installed.
  readonly property string scriptPath: decodeURIComponent(
    Qt.resolvedUrl("scripts/dict-lookup").toString().replace(/^file:\/\//, ""))

  // --- theme tokens (share the [menu] surface, like the emoji/clipboard popups)
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color accent: Color.accent
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  readonly property int contentMargin: Style.spacing.panelPadding
  readonly property int gap: Style.spacing.md

  readonly property int cardWidth: Math.min(Style.space(560), panel.width - Style.gapsOut * 4)
  readonly property int cardHeight: Math.min(Style.space(620), panel.height - Style.gapsOut * 4)

  function emptyResult() {
    return { query: "", word: "", found: false, sections: [], suggestions: [] }
  }

  // --- lifecycle (called by the shell host) --------------------------------
  function open(payloadJson) {
    var p = ({})
    try { p = JSON.parse(payloadJson || "{}") } catch (e) { p = ({}) }
    root.opened = true
    setQuery(String(p.query || "").slice(0, 400))
    Qt.callLater(function () {
      searchField.forceActiveFocus()
      searchField.selectAll()
    })
  }

  function close() { root.opened = false }

  function dismiss() {
    root.close()
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide(root.pluginId)
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  function setQuery(q) {
    root.query = q
    if (searchField.text !== q) searchField.text = q
    if (q.trim().length > 0) runLookup(q)
    else { root.result = emptyResult(); root.loading = false }
  }

  // --- lookup process ------------------------------------------------------
  property string _pending: ""
  property bool _relaunch: false
  // Bound the helper so a hung or oversized subprocess can never wedge or
  // exhaust the shell process.
  readonly property int lookupTimeoutMs: 8000
  readonly property int maxOutputChars: 2000000    // ~2 MB; our JSON is far smaller

  function runLookup(q) {
    root._pending = q
    root.loading = true
    if (lookupProc.running) root._relaunch = true
    else _launch()
  }

  function _launch() {
    if (root._pending.trim().length === 0) { root.loading = false; return }
    // Absolute interpreter path — never resolve `bash` through an inherited PATH.
    lookupProc.command = ["/usr/bin/bash", root.scriptPath, root._pending]
    watchdog.restart()
    lookupProc.running = true
  }

  function _finish(r) {
    watchdog.stop()
    root.result = r
    if (root._pending && root._pending !== (r.query || "")) root._relaunch = true
    else root.loading = false
  }

  function _onResult(txt) {
    // Cap buffered output before parsing so an oversized result cannot blow up
    // the shell process.
    if (txt && txt.length > root.maxOutputChars) { _finish(emptyResult()); return }
    var r
    try { r = JSON.parse(txt) } catch (e) { r = emptyResult() }
    _finish(r)
  }

  Process {
    id: lookupProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root._onResult(text)
    }
    onRunningChanged: {
      if (!running && root._relaunch) { root._relaunch = false; root._launch() }
    }
  }

  // Terminates a lookup that runs too long (a hung or replaced helper) and clears
  // the UI. Cancelling _relaunch first means the async termination won't respawn it.
  Timer {
    id: watchdog
    interval: root.lookupTimeoutMs
    repeat: false
    onTriggered: {
      root._relaunch = false
      root.loading = false
      root.result = root.emptyResult()
      if (lookupProc.running) lookupProc.running = false
    }
  }

  // --- Webster blob -> lightly styled rich text ---------------------------
  function fmtDefinition(s) {
    if (!s) return ""
    var t = String(s)
    t = t.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    t = t.replace(/Defn:\s*/g, "")
    // etymology / cross-references in [ ... ] -> italic
    t = t.replace(/\[([^\]]{1,160})\]/g, "<i>[$1]</i>")
    // Sense numbers -> bold headings, but ONLY genuine ones. Webster's text is
    // full of incidental numbers (scripture citations like "Heb. xi. 6.",
    // cross-references, quantities) that must not be mistaken for senses. A
    // real sense number is either the next in sequence, or a "1." starting a
    // new part-of-speech block (Webster restarts numbering per part of speech).
    // The trailing space is matched with a lookahead so it is not consumed —
    // otherwise a citation like "Gal. i. 23." would swallow the space before
    // the real sense "5." that follows and hide it entirely.
    var next = 1
    function promote(n) {
      if (n === next) { next += 1; return true }
      if (n === 1) { next = 2; return true }
      return false
    }
    // leading sense number "1." (no paragraph break before the first one)
    t = t.replace(/^\s*(\d{1,2})\.(?=\s)/, function (m, n) {
      return promote(parseInt(n, 10)) ? "<b>" + n + ".</b>" : m
    })
    // "-- 2." style sense breaks and bare " 2. " -> new paragraph + bold
    t = t.replace(/(\s+)(?:--\s+)?(\d{1,2})\.(?=\s)/g, function (m, ws, n) {
      return promote(parseInt(n, 10)) ? "<br><br><b>" + n + ".</b>" : m
    })
    // editorial labels onto their own line
    t = t.replace(/\s+(Note:|Syn\.|Usage:)\s*/g, "<br><i>$1</i> ")
    t = t.replace(/[ \t]{2,}/g, " ")
    return t.trim()
  }

  // ------------------------------------------------------------------------
  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-lookup"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    // dimmed backdrop; click to dismiss
    Rectangle {
      anchors.fill: parent
      color: root.scrim
      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: root.dismiss()
      }
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      // Swallow clicks on the card so they don't fall through to the backdrop.
      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.RightButton
        onClicked: root.dismiss()
      }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.gap

        // --- search row ------------------------------------------------
        Item {
          width: parent.width
          height: searchField.implicitHeight

          Text {
            id: glyph
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: root.loading ? "󰦖" : "󰍉"
            color: root.foreground
            opacity: 0.7
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
          }

          TextField {
            id: searchField
            anchors.left: glyph.right
            anchors.leftMargin: Style.spacing.sm
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            placeholderText: "Look up a word…"
            foreground: root.foreground
            accent: root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading

            onTextChanged: {
              root.query = text
              debounce.restart()
            }
            onAccepted: {
              debounce.stop()
              if (text.trim().length > 0) root.runLookup(text)
            }
            Keys.onEscapePressed: function (e) {
              if (searchField.text.length > 0) root.setQuery("")
              else root.dismiss()
              e.accepted = true
            }
          }

          Timer {
            id: debounce
            interval: 200
            onTriggered: {
              if (searchField.text.trim().length > 0) root.runLookup(searchField.text)
              else { root.result = root.emptyResult(); root.loading = false }
            }
          }
        }

        PanelSeparator { width: parent.width }

        // --- results body ---------------------------------------------
        Flickable {
          id: scroller
          width: parent.width
          height: parent.height - y
          clip: true
          contentWidth: width
          contentHeight: body.implicitHeight
          boundsBehavior: Flickable.StopAtBounds
          flickableDirection: Flickable.VerticalFlick

          Column {
            id: body
            width: scroller.width
            spacing: Style.spacing.lg

            // Empty / hint state
            Column {
              width: parent.width
              spacing: Style.spacing.sm
              visible: root.query.trim().length === 0

              Text {
                text: "󰈙"
                color: root.foreground
                opacity: 0.45
                font.family: root.fontFamily
                font.pixelSize: Style.font.displayLarge
              }
              Text {
                width: parent.width
                wrapMode: Text.Wrap
                text: "Type a word above — or select any text and press your Look Up shortcut."
                color: root.foreground
                opacity: 0.6
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }

            // Found: one section per dictionary, in configured order
            Repeater {
              model: root.result.found ? root.result.sections : []

              Column {
                required property var modelData
                width: body.width
                spacing: Style.spacing.sm
                visible: modelData.entries && modelData.entries.length > 0

                // dictionary source label
                Text {
                  text: (modelData.name || modelData.id || "").toUpperCase()
                  color: root.accent
                  opacity: 0.85
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 1
                }

                Repeater {
                  model: modelData.entries

                  Column {
                    required property var modelData
                    width: body.width
                    spacing: Style.spacing.xs
                    topPadding: Style.spacing.xs

                    Text {
                      text: modelData.headword || root.result.word
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.title
                      font.bold: true
                    }
                    Text {
                      width: parent.width
                      textFormat: Text.RichText
                      text: root.fmtDefinition(modelData.text)
                      color: root.foreground
                      opacity: 0.92
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      wrapMode: Text.Wrap
                      lineHeight: 1.15
                    }
                  }
                }
              }
            }

            // Not found: message + "did you mean" chips
            Column {
              width: parent.width
              spacing: Style.spacing.md
              visible: !root.result.found && !root.loading && root.query.trim().length > 0

              Text {
                width: parent.width
                wrapMode: Text.Wrap
                text: "No definition for “" + root.query.trim() + "”."
                color: root.foreground
                opacity: 0.85
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
              }

              Text {
                visible: (root.result.suggestions || []).length > 0
                text: "Did you mean…"
                color: root.foreground
                opacity: 0.6
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Flow {
                width: parent.width
                spacing: Style.spacing.sm
                visible: (root.result.suggestions || []).length > 0

                Repeater {
                  model: root.result.suggestions || []

                  Rectangle {
                    required property var modelData
                    radius: root.cornerRadius > 0 ? root.cornerRadius : Style.space(6)
                    color: chipHover.containsMouse ? root.accent : root.selectedBackground
                    implicitWidth: chipText.implicitWidth + Style.spacing.lg * 2
                    implicitHeight: chipText.implicitHeight + Style.spacing.sm * 2

                    Text {
                      id: chipText
                      anchors.centerIn: parent
                      text: modelData
                      color: chipHover.containsMouse ? root.background : root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                    }
                    MouseArea {
                      id: chipHover
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.setQuery(modelData)
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
