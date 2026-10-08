import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "AppleMusicModel.js" as Model

// The widget's options popup. It only edits persisted plugin settings — the
// lyrics toggle and its font, and how fast the song list scrolls — through
// `omarchy bar set`, so the player panel picks the changes up from its own
// injected settings. Opened from the player panel's gear button; the host
// widget owns the popout, so this panel just shows and hides.
Panel {
  id: root
  moduleName: Model.PLUGIN_ID
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var service: hostWidget ? hostWidget.service : null

  readonly property var barIdentity: hostWidget || root
  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  // ---- Settings (the same keys PlayerPanel reads) --------------------------
  function truthy(value, fallback) {
    if (value === true || value === "true") return true
    if (value === false || value === "false") return false
    return fallback
  }

  readonly property bool lyricsOn: root.truthy(setting("lyrics", false), false)
  readonly property string lyricsFont: {
    var value = setting("lyricsFont", "")
    return value === undefined || value === null ? "" : String(value)
  }
  readonly property int lyricsSize: {
    var value = Number(setting("lyricsSize", 16))
    return isFinite(value) ? Math.max(12, Math.min(32, Math.round(value))) : 16
  }
  readonly property real scrollSpeed: {
    var value = Number(setting("scrollSpeed", 1))
    return isFinite(value) ? Math.max(0.5, Math.min(4, value)) : 1
  }

  // The font field edits a draft so typing never fights the binding; it is
  // committed on Enter/defocus and re-synced whenever the stored value lands.
  property string fontDraft: root.lyricsFont
  onLyricsFontChanged: root.fontDraft = root.lyricsFont

  // `--json` keeps booleans and numbers typed in shell.json; plain strings are
  // stored as strings by omarchy bar set.
  function persist(key, value, isJson) {
    var args = ["omarchy", "bar", "set", Model.PLUGIN_ID, key, String(value)]
    if (isJson) args.push("--json")
    Quickshell.execDetached(args)
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: fontField.activeFocus
      onCloseRequested: root.close()

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        // ---- Header: title plus a close button.
        Row {
          width: parent.width
          spacing: Style.space(8)

          Text {
            width: parent.width - closeButton.width - parent.spacing
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: "Options"
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }

          PanelActionButton {
            id: closeButton
            anchors.verticalCenter: parent.verticalCenter
            iconText: "󰅖"
            tooltipText: "Close"
            onClicked: root.close()
          }
        }

        PanelSeparator { foreground: root.contentForeground }

        // ---- Lyrics: on/off, the font it renders in, and its size.
        Row {
          width: parent.width
          spacing: Style.space(8)

          Text {
            width: parent.width - lyricsToggle.width - parent.spacing
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: "Lyrics"
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
          }

          ButtonGroup {
            id: lyricsToggle
            anchors.verticalCenter: parent.verticalCenter
            options: [
              { value: "on", label: "On" },
              { value: "off", label: "Off" }
            ]
            value: root.lyricsOn ? "on" : "off"
            onChanged: function(v) { root.persist("lyrics", v === "on", true) }
          }
        }

        Column {
          width: parent.width
          spacing: Style.space(4)

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: "Lyrics font"
            color: Qt.darker(root.contentForeground, 1.4)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
          }

          TextField {
            id: fontField
            width: parent.width
            placeholderText: "Theme default"
            text: root.fontDraft
            onTextChanged: root.fontDraft = text
            onEditingFinished: root.persist("lyricsFont", root.fontDraft.trim(), false)
          }
        }

        Row {
          width: parent.width
          spacing: Style.space(8)

          TextMetrics {
            id: sizeSample
            text: "Size"
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
          }

          TextMetrics {
            id: sizeValueSample
            text: "00 pt"
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
          }

          Text {
            width: sizeSample.width
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: "Size"
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
          }

          PanelSlider {
            id: sizeSlider
            width: parent.width - sizeSample.width - sizeValueSample.width - parent.spacing * 2
            anchors.verticalCenter: parent.verticalCenter
            bar: root.bar
            value: root.lyricsSize
            minimum: 12
            maximum: 32
            step: 1
            integer: true
            onReleased: function(v) { root.persist("lyricsSize", Math.round(v), true) }
          }

          Text {
            width: sizeValueSample.width
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.lyricsSize + " pt"
            color: Qt.darker(root.contentForeground, 1.3)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
          }
        }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: "The quick brown fox — 0123"
          wrapMode: Text.WordWrap
          color: Qt.darker(root.contentForeground, 1.1)
          font.family: root.lyricsFont !== "" ? root.lyricsFont : root.contentFontFamily
          font.pixelSize: root.lyricsSize
          padding: Style.space(6)
        }

        PanelSeparator { foreground: root.contentForeground }

        // ---- Scroll speed: multiplies both the wheel and the keyboard steps.
        Row {
          width: parent.width
          spacing: Style.space(8)

          TextMetrics {
            id: speedSample
            text: "Scroll speed"
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
          }

          TextMetrics {
            id: speedValueSample
            text: "0.0×"
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
          }

          Text {
            width: speedSample.width
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: "Scroll speed"
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
          }

          PanelSlider {
            id: speedSlider
            width: parent.width - speedSample.width - speedValueSample.width - parent.spacing * 2
            anchors.verticalCenter: parent.verticalCenter
            bar: root.bar
            value: root.scrollSpeed
            minimum: 0.5
            maximum: 4
            step: 0.5
            onReleased: function(v) { root.persist("scrollSpeed", Math.round(v * 2) / 2, true) }
          }

          Text {
            width: speedValueSample.width
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.scrollSpeed.toFixed(1) + "×"
            color: Qt.darker(root.contentForeground, 1.3)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
          }
        }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: "How far one wheel notch or arrow key moves through the song list."
          wrapMode: Text.WordWrap
          color: Qt.darker(root.contentForeground, 1.4)
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
