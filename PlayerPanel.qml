import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "AppleMusicModel.js" as Model
import "PanelModel.js" as PanelModel

// The widget's popup: a simple Apple Music player — now playing, transport,
// seek — with playlist picking and catalog browse/search, all driven through
// the page bridge (control.sh bridge / bridge-state). The web app itself
// stays reachable behind "Open Apple Music".
//
// BarWidget.qml owns the bar mark and hands this panel the anchor to sit
// under, plus the service that talks to the browser.
Panel {
  id: root
  moduleName: Model.PLUGIN_ID
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  // Bound through the host widget (rather than injected) so the service
  // reference stays fresh if the bar resolves it after this panel loads.
  readonly property var service: hostWidget ? hostWidget.service : null

  readonly property var barIdentity: hostWidget || root
  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  // Named playerState: Item already owns `state` (QQuickItem.state).
  readonly property var playerState: service ? service.bridgeState : PanelModel.normalizeState(null)
  readonly property bool ready: playerState.ready === true
  readonly property bool playing: ready && playerState.playing === true
  readonly property bool hasTrack: ready && (playerState.title !== "" || playerState.artist !== "")

  property string activeTab: "playlists"
  property string pendingSearch: ""
  property int selectedIndex: -1
  property bool cursorActive: false

  readonly property string tabLabel: activeTab === "playlists"
    ? "Playlists" : activeTab === "browse" ? "Browse" : "Search"

  function open() {
    refreshData()
    root.controller.show()
    // Set after showing, not before: showing hands the popout coordinator
    // over, which closes whichever panel was open, and that close clears the
    // shared flag. Deferring means the panel taking over always wins.
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    root.selectedIndex = -1
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // Summoning by hotkey moves no pointer, so a hover the bar was still
  // holding must not keep the center indicators revealed behind the panel.
  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
    else if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  function refreshData() {
    if (!service) return
    service.setBridgePolling(true)
    if (service.bridgePlaylists.length === 0)
      service.runBridge("playlists", { limit: 50 }, "playlists")
    if (service.bridgeRecent.length === 0)
      service.runBridge("recentlyAdded", { limit: 12 }, "recentlyAdded")
    if (service.bridgeCharts.length === 0)
      service.runBridge("charts", { limit: 12 }, "charts")
  }

  function playRow(row) {
    if (!service || !row) return
    var command = PanelModel.playCommandFor(row)
    if (command.id === "") return
    service.runBridge(command.op, { id: command.id })
    root.selectedIndex = -1
    Qt.callLater(function() { root.close() })
  }

  function sendTransport(op) {
    if (!service) return
    if (root.ready) {
      service.runBridge(op)
    } else {
      // No bridge (bridge down or page not loaded) — MPRIS still controls
      // the browser's own player.
      var action = op === "toggle" ? "playPause" : op
      service.runAction(action)
    }
  }

  function toggleShuffle() {
    if (service) service.runBridge("shuffle", { on: !root.playerState.shuffle })
  }

  function cycleRepeat() {
    if (!service) return
    var next = root.playerState.repeat === "off" ? "all" : root.playerState.repeat === "all" ? "one" : "off"
    service.runBridge("repeat", { mode: next })
  }

  function runSearch() {
    var term = root.pendingSearch.trim()
    if (!service || term === "") return
    service.runBridge("search", { term: term, limit: 20 }, "search")
    root.selectedIndex = -1
  }

  function selectTab(tab) {
    if (root.activeTab === tab) return
    root.activeTab = tab
    root.selectedIndex = -1
    if (tab === "search") Qt.callLater(function() { searchField.forceActiveFocus() })
  }

  function moveSelection(delta) {
    if (rowsRepeater.count === 0) return
    var next = root.selectedIndex
    for (var step = 0; step < rowsRepeater.count; step++) {
      next += delta
      if (next < 0) next = rowsRepeater.count - 1
      if (next >= rowsRepeater.count) next = 0
      if (root.entries[next] && root.entries[next].row) break
    }
    if (!root.entries[next] || !root.entries[next].row) return
    root.cursorActive = true
    root.selectedIndex = next
    ensureSelectionVisible()
  }

  function ensureSelectionVisible() {
    var item = rowsRepeater.itemAt(root.selectedIndex)
    if (!item || !listFlick) return
    var top = item.mapToItem(rowsColumn, 0, 0).y
    var bottom = top + item.height
    if (top < listFlick.contentY)
      listFlick.contentY = Math.max(0, top)
    else if (bottom > listFlick.contentY + listFlick.height)
      listFlick.contentY = Math.min(listFlick.contentHeight - listFlick.height, bottom - listFlick.height)
  }

  function activateSelection() {
    if (root.selectedIndex >= 0 && root.entries[root.selectedIndex]) {
      playRow(root.entries[root.selectedIndex].row)
    } else {
      sendTransport("toggle")
    }
  }

  // One flat display model: section headers interleave with rows, so a
  // single Repeater renders every tab and the keyboard cursor just skips
  // the header entries.
  readonly property var entries: {
    var out = []
    var push = function(label, rows) {
      if (!rows || rows.length === 0) return
      out.push({ header: label, row: null })
      for (var i = 0; i < rows.length; i++) out.push({ header: "", row: rows[i] })
    }
    if (!service) return out
    if (activeTab === "playlists") {
      push("", service.bridgePlaylists)
    } else if (activeTab === "browse") {
      push("RECENTLY ADDED", service.bridgeRecent)
      push("TOP PLAYLISTS", service.bridgeCharts)
    } else {
      var sections = service.bridgeSearchSections
      for (var s = 0; s < sections.length; s++) push(sections[s].label, sections[s].rows)
    }
    return out
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(460))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: searchField.activeFocus
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.moveSelection(dy > 0 ? 1 : -1)
        else if (dx !== 0) root.selectTab(dx > 0
          ? (root.activeTab === "playlists" ? "browse" : "search")
          : (root.activeTab === "search" ? "browse" : "playlists"))
      }
      onActivateRequested: root.activateSelection()
      onReturnRequested: root.activateSelection()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === " ") root.sendTransport("toggle")
        else if (t === "s" || t === "S") root.selectTab("search")
      }

      Flickable {
        id: listFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: contentColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: contentColumn
          width: listFlick.width
          spacing: Style.space(12)

          // ---- Hero: artwork, title, artist, and the escape hatch to the
          //      full web app.
          Item {
            width: parent.width
            height: heroRow.height

            Row {
              id: heroRow
              anchors.left: parent.left
              anchors.right: parent.right
              spacing: Style.space(12)

              Rectangle {
                id: artworkFrame
                width: Style.space(56)
                height: width
                radius: Style.cornerRadius
                color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.08)
                anchors.verticalCenter: parent.verticalCenter

                Text {
                  anchors.centerIn: parent
                  visible: artwork.status !== Image.Ready
                  text: "󰝚"
                  color: root.contentForeground
                  opacity: 0.5
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.title
                }

                Image {
                  id: artwork
                  anchors.fill: parent
                  anchors.margins: 1
                  source: PanelModel.artworkUrl(root.playerState.artwork, 112)
                  fillMode: Image.PreserveAspectCrop
                  asynchronous: true
                  clip: true
                }
              }

              Column {
                width: parent.width - artworkFrame.width - Style.space(12) - heroButton.width - Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  text: root.hasTrack ? root.playerState.title : (root.ready ? "Nothing playing" : "Apple Music")
                  color: root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.title
                  font.bold: true
                  elide: Text.ElideRight
                }

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  text: root.hasTrack
                    ? [root.playerState.artist, root.playerState.album].filter(function(v) { return v !== "" }).join(" — ")
                    : (root.ready ? "Pick something below" : "Not connected")
                  color: Qt.darker(root.contentForeground, 1.4)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }
              }

              Button {
                id: heroButton
                anchors.verticalCenter: parent.verticalCenter
                text: root.service ? "Open Apple Music" : "Unavailable"
                enabled: !!root.service
                tooltipText: "Show the full Apple Music window"
                onClicked: {
                  if (root.hostWidget && typeof root.hostWidget.openWindow === "function") {
                    root.close()
                    root.hostWidget.openWindow()
                  }
                }
              }
            }
          }

          // ---- Seek bar with elapsed / total times.
          Row {
            width: parent.width
            spacing: Style.space(8)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: PanelModel.formatTime(root.playerState.position)
              color: Qt.darker(root.contentForeground, 1.3)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
            }

            PanelSlider {
              id: seekSlider
              width: parent.width - parent.spacing * 2 - timeLabels.implicitWidth
              bar: root.bar
              value: root.playerState.position
              minimum: 0
              maximum: Math.max(1, root.playerState.duration)
              enabled: root.ready && root.playerState.duration > 0
              onReleased: function(v) {
                if (root.service && root.ready)
                  root.service.runBridge("seek", { position: Math.max(0, Math.round(v)) })
              }
            }

            Text {
              id: timeLabels
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: PanelModel.formatTime(root.playerState.duration)
              color: Qt.darker(root.contentForeground, 1.3)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
            }
          }

          // ---- Transport.
          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(14)

            PanelActionButton {
              anchors.verticalCenter: parent.verticalCenter
              iconText: "󰒝"
              tooltipText: "Shuffle"
              foreground: root.playerState.shuffle ? Color.accent : root.contentForeground
              enabled: root.ready
              onClicked: root.toggleShuffle()
            }

            PanelActionButton {
              anchors.verticalCenter: parent.verticalCenter
              iconText: "󰒮"
              tooltipText: "Previous"
              enabled: root.ready || root.service !== null
              onClicked: root.sendTransport("previous")
            }

            PanelActionButton {
              anchors.verticalCenter: parent.verticalCenter
              size: Math.max(Style.space(32), Style.font.icon + Style.spacing.md * 2)
              iconText: root.playing ? "󰏤" : "󰐊"
              tooltipText: root.playing ? "Pause" : "Play"
              enabled: root.service !== null
              onClicked: root.sendTransport("toggle")
            }

            PanelActionButton {
              anchors.verticalCenter: parent.verticalCenter
              iconText: "󰒭"
              tooltipText: "Next"
              enabled: root.ready || root.service !== null
              onClicked: root.sendTransport("next")
            }

            PanelActionButton {
              anchors.verticalCenter: parent.verticalCenter
              iconText: root.playerState.repeat === "one" ? "󰑖" : "󰕇"
              tooltipText: "Repeat: " + root.playerState.repeat
              foreground: root.playerState.repeat !== "off" ? Color.accent : root.contentForeground
              enabled: root.ready
              onClicked: root.cycleRepeat()
            }
          }

          PanelSeparator { foreground: root.contentForeground }

          // ---- Tabs: Playlists / Browse / Search.
          Row {
            width: parent.width
            spacing: Style.space(8)

            ButtonGroup {
              id: tabsGroup
              anchors.verticalCenter: parent.verticalCenter
              options: [
                { value: "playlists", label: "Playlists" },
                { value: "browse", label: "Browse" },
                { value: "search", label: "Search" }
              ]
              value: root.activeTab
              onChanged: function(v) { root.selectTab(v) }
            }

            Item { width: parent.width - tabsGroup.width - refreshButton.width - Style.space(16); height: 1 }

            PanelActionButton {
              id: refreshButton
              anchors.verticalCenter: parent.verticalCenter
              iconText: "󰑓"
              tooltipText: "Refresh"
              onClicked: {
                if (!root.service) return
                root.service.runBridge("playlists", { limit: 50 }, "playlists")
                root.service.runBridge("recentlyAdded", { limit: 12 }, "recentlyAdded")
                root.service.runBridge("charts", { limit: 12 }, "charts")
                if (root.activeTab === "search") root.runSearch()
              }
            }
          }

          // ---- Search field, only on the Search tab.
          Row {
            visible: root.activeTab === "search"
            width: parent.width
            spacing: Style.space(8)

            TextField {
              id: searchField
              width: parent.width - searchButton.width - parent.spacing
              placeholderText: "Songs, albums, playlists…"
              text: root.pendingSearch
              onTextChanged: root.pendingSearch = text
              onAccepted: root.runSearch()
            }

            Button {
              id: searchButton
              anchors.verticalCenter: parent.verticalCenter
              text: "Search"
              onClicked: root.runSearch()
            }
          }

          Text {
            visible: root.entries.length === 0
            textFormat: Text.PlainText
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: !root.service
              ? "The widget service is unavailable"
              : root.activeTab === "search"
                ? (root.service.bridgeSearchTerm === "" ? "Search your catalog" : "No results")
                : "Nothing here yet"
            color: Qt.darker(root.contentForeground, 1.4)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
            padding: Style.space(12)
          }

          Text {
            visible: root.service && root.service.bridgeError !== ""
            textFormat: Text.PlainText
            width: parent.width
            text: root.service ? root.service.bridgeError : ""
            color: Color.urgent
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          // ---- Rows: one model for every tab; headers break up sections.
          Column {
            id: rowsColumn
            width: parent.width
            spacing: 0

            Repeater {
              id: rowsRepeater
              model: root.entries

              delegate: Item {
                id: rowEntry
                required property var modelData
                required property int index

                readonly property bool isHeader: modelData.header !== ""
                readonly property var row: modelData.row
                readonly property bool isSelected: root.cursorActive && root.selectedIndex === index
                width: rowsColumn.width
                height: isHeader ? headerLabel.implicitHeight + Style.space(10) : Style.space(44)

                Text {
                  id: headerLabel
                  visible: parent.isHeader
                  anchors.top: parent.top
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(6)
                  textFormat: Text.PlainText
                  text: parent.modelData.header
                  color: Qt.darker(root.contentForeground, 1.4)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  topPadding: Math.ceil(Style.font.caption * 0.15)
                }

                CursorSurface {
                  visible: !parent.isHeader
                  anchors.fill: parent
                  hasCursor: parent.isSelected
                  current: false
                  foreground: root.contentForeground

                  Row {
                    anchors.fill: parent
                    anchors.leftMargin: Style.space(6)
                    anchors.rightMargin: Style.space(6)
                    spacing: Style.space(10)

                    Rectangle {
                      width: Style.space(32)
                      height: width
                      radius: Style.cornerRadius * 0.6
                      anchors.verticalCenter: parent.verticalCenter
                      color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.08)

                      Text {
                        anchors.centerIn: parent
                        visible: thumb.status !== Image.Ready
                        text: rowEntry.row && rowEntry.row.kind === "playlist" ? "󰲱" : "󰝚"
                        color: root.contentForeground
                        opacity: 0.5
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.body
                      }

                      Image {
                        id: thumb
                        anchors.fill: parent
                        anchors.margins: 1
                        source: rowEntry.row ? PanelModel.artworkUrl(rowEntry.row.artwork, 64) : ""
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        clip: true
                      }
                    }

                    Column {
                      width: parent.width - Style.space(32) - Style.space(10) - playGlyph.width - Style.space(10)
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: 1

                      Text {
                        textFormat: Text.PlainText
                        width: parent.width
                        text: rowEntry.row ? rowEntry.row.name : ""
                        color: root.contentForeground
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.body
                        elide: Text.ElideRight
                      }

                      Text {
                        textFormat: Text.PlainText
                        width: parent.width
                        visible: text !== ""
                        text: rowEntry.row ? rowEntry.row.subtitle : ""
                        color: Qt.darker(root.contentForeground, 1.4)
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideRight
                      }
                    }

                    Text {
                      id: playGlyph
                      anchors.verticalCenter: parent.verticalCenter
                      text: "󰐊"
                      opacity: rowMouse.containsMouse ? 1.0 : 0.0
                      color: root.contentForeground
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.icon
                      Behavior on opacity { NumberAnimation { duration: 120 } }
                    }
                  }

                  MouseArea {
                    id: rowMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onContainsMouseChanged: {
                      if (containsMouse) {
                        root.cursorActive = true
                        root.selectedIndex = rowEntry.index
                      }
                    }
                    onClicked: root.playRow(rowEntry.row)
                  }
                }
              }
            }
          }

          Item { width: 1; height: Style.space(4) }
        }
      }
    }
  }
}
