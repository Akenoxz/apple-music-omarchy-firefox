import QtQuick
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

  // A click starts a row without dismissing the panel (only the bar icon or
  // losing focus closes it). The clicked row stays highlighted as the thing
  // this panel launched, and whatever title the page reports as current is
  // highlighted too.
  property string requestedRowId: ""
  readonly property string nowPlayingId: String(playerState.id || "")

  // Drill-in view: a playlist, an album and an artist each open their own
  // page — an album opens its songs rather than playing from the top, so
  // nothing starts until a track is picked. A song picked there starts the
  // surrounding list so it keeps playing.
  property string detailKind: ""
  property string detailId: ""
  property string detailName: ""
  readonly property bool detailOpen: root.detailId !== ""
  // Only the reply matching the open item is shown, so the previous playlist,
  // album or artist never flashes while the fresh reply is in flight.
  readonly property string detailReplyId: service === null ? ""
    : root.detailKind === "artist" ? String(service.bridgeArtistId)
    : root.detailKind === "album" ? String(service.bridgeAlbumId)
    : String(service.bridgePlaylistId)
  readonly property bool detailLoaded: service !== null && root.detailReplyId === root.detailId
  readonly property var detailSongs: root.detailLoaded
    ? (root.detailKind === "artist" ? service.bridgeArtistSongs
      : root.detailKind === "album" ? service.bridgeAlbumTracks
      : service.bridgePlaylistTracks)
    : []
  readonly property var detailAlbums: root.detailKind === "artist" && root.detailLoaded
    ? service.bridgeArtistAlbums : []

  // The player chrome never scrolls; only the songs do. The
  // list gets the room left inside the card's maximum height, and the card
  // shrinks to fit when the content is short. This mirrors
  // KeyboardPanel.fittedContentHeight, which adds the card's vertical inset
  // before clamping to its cap.
  readonly property real cardMax: {
    var available = panel.availableCardHeight > 0 ? panel.availableCardHeight : Style.space(620)
    return Math.max(Style.space(120), Math.min(Style.space(620), available))
  }
  readonly property real listContentHeight: rowsColumn.implicitHeight
  readonly property real listHeight: {
    var room = root.cardMax - panel.verticalContentInset - chromeColumn.implicitHeight
      - Style.space(12) * 2 - Style.space(4)
    return Math.min(root.listContentHeight, Math.max(Style.space(64), room))
  }

  // The bridge publishes a few times a second. Interpolating in between keeps
  // the seek bar moving like a player instead of stepping, and resyncs to the
  // published position every time a new snapshot lands.
  property double displayPosition: 0
  property double positionStamp: 0

  readonly property bool loading: service ? service.bridgeLoading === true : false
  readonly property bool reconnecting: ready && service !== null && service.bridgeStale === true

  function syncPosition() {
    root.displayPosition = root.playerState.position
    root.positionStamp = Date.now()
  }

  function rowActive(row) {
    if (!row || row.id === "") return false
    return row.id === root.requestedRowId || row.id === root.nowPlayingId
  }

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
    root.closeDetail()
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
    // One round trip covers both list tabs: the page runs the library and
    // chart requests in parallel. Rows already cached stay on screen while the
    // fresh reply lands, so reopening the panel never shows an empty shell.
    service.runBridge("browse", { playlists: 50, recent: 12, charts: 12 }, "browse")
  }

  onPlayerStateChanged: root.syncPosition()
  Component.onCompleted: root.syncPosition()

  // The list a song row was picked from, shaped for the bridge: the search
  // results it came from, or the playlist the panel drilled into. Without it
  // the song plays alone and stops when it ends.
  function queueFor(row) {
    if (!row || row.kind !== "song") return null
    if (root.detailOpen) {
      // An artist's top songs and an album's track list play as their own
      // list; a playlist is queued by id so MusicKit keeps it in order.
      if (root.detailKind === "artist" || root.detailKind === "album")
        return { ids: PanelModel.songQueue(root.detailSongs, row) }
      return { playlist: root.detailId }
    }
    var sections = service ? service.bridgeSearchSections : []
    for (var i = 0; i < sections.length; i++) {
      if (sections[i].key === "songs")
        return { ids: PanelModel.songQueue(sections[i].rows, row) }
    }
    return null
  }

  function playRow(row) {
    if (!service || !row) return
    // A container opens instead of playing: an album, a playlist and an artist
    // all have a page to choose from, and clicking one is browsing rather than
    // a decision to start the first track. A song plays, in the context of the
    // list it was picked from.
    var action = PanelModel.rowAction(row)
    if (action === "openPlaylist") { root.openPlaylist(row); return }
    if (action === "openArtist") { root.openArtist(row); return }
    if (action === "openAlbum") { root.openAlbum(row); return }
    var command = PanelModel.playCommandFor(row, root.queueFor(row))
    if (command.id === "") return
    root.requestedRowId = command.id
    service.runBridge(command.op, command)
  }

  function openDetail(kind, row) {
    if (!service || !row || row.id === "") return
    root.detailKind = kind
    root.detailId = String(row.id)
    root.detailName = String(row.name || "")
    root.selectedIndex = -1
    root.cursorActive = false
    root.refreshDetail()
  }

  function openPlaylist(row) { root.openDetail("playlist", row) }
  function openArtist(row) { root.openDetail("artist", row) }
  function openAlbum(row) { root.openDetail("album", row) }

  function closeDetail() {
    root.detailKind = ""
    root.detailId = ""
    root.detailName = ""
    root.selectedIndex = -1
    root.cursorActive = false
  }

  function refreshDetail() {
    if (!service || !root.detailOpen) return
    if (root.detailKind === "artist")
      service.runBridge("artistDetail", { id: root.detailId, limit: 20 }, "artistDetail")
    else if (root.detailKind === "album")
      // No limit: an album's tracks relationship refuses one upstream.
      service.runBridge("albumDetail", { id: root.detailId }, "albumDetail")
    else
      service.runBridge("playlistTracks", { id: root.detailId, limit: 100 }, "playlistTracks")
  }

  // Esc backs out of a playlist or artist view before it closes the panel.
  function closeDetailOrClose() {
    if (root.detailOpen) root.closeDetail()
    else root.close()
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
    if (root.detailOpen) root.closeDetail()
    if (root.activeTab === tab) return
    root.activeTab = tab
    root.selectedIndex = -1
    if (tab === "search") Qt.callLater(function() { searchField.forceActiveFocus() })
  }

  // One arrow key crosses as many rows as one wheel notch does, so a long
  // list is reachable from the keyboard too.
  function moveSelection(delta) {
    for (var step = 0; step < PanelModel.SCROLL_ROWS; step++) root.moveSelectionOnce(delta)
  }

  function moveSelectionOnce(delta) {
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
    if (root.detailOpen) {
      if (root.detailKind === "artist") {
        push("TOP SONGS", root.detailSongs)
        push("ALBUMS", root.detailAlbums)
      } else {
        push("", root.detailSongs)
      }
      return out
    }
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

  Timer {
    id: positionTick
    interval: 100
    repeat: true
    running: root.playing && !seekSlider.dragging
    onTriggered: {
      var advanced = root.playerState.position + (Date.now() - root.positionStamp) / 1000
      var span = root.playerState.duration
      root.displayPosition = span > 0 ? Math.min(advanced, span) : advanced
    }
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
      onCloseRequested: root.closeDetailOrClose()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === " ") root.sendTransport("toggle")
        else if (t === "s" || t === "S") root.selectTab("search")
      }

      Column {
        id: contentColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        // Static chrome: everything above the song list. The player, seek bar,
        // transport and tabs stay put while the list below scrolls.
        Column {
          id: chromeColumn
          width: parent.width
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

          // ---- Seek bar with elapsed / total times. Both labels keep one
          //      width for the whole track, so nothing shifts while it plays.
          Row {
            width: parent.width
            spacing: Style.space(8)

            TextMetrics {
              id: timeSample
              text: "00:00"
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              width: timeSample.width
              horizontalAlignment: Text.AlignRight
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: PanelModel.formatTime(root.displayPosition)
              color: Qt.darker(root.contentForeground, 1.3)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
            }

            PanelSlider {
              id: seekSlider
              width: parent.width - parent.spacing * 2 - timeSample.width * 2
              bar: root.bar
              value: root.displayPosition
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
              width: timeSample.width
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

          // ---- Tabs: Playlists / Browse / Search, plus the refresh action.
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

            Item {
              width: Math.max(0, parent.width - tabsGroup.width - actionsRow.width - Style.space(16))
              height: 1
            }

            Row {
              id: actionsRow
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(4)

              PanelActionButton {
                id: refreshButton
                anchors.verticalCenter: parent.verticalCenter
                iconText: "󰑓"
                tooltipText: "Refresh"
                onClicked: {
                  if (!root.service) return
                  if (root.detailOpen) { root.refreshDetail(); return }
                  root.service.runBridge("browse", { playlists: 50, recent: 12, charts: 12 }, "browse")
                  if (root.activeTab === "search") root.runSearch()
                }
              }
            }
          }

          // ---- Search field, only on the Search tab.
          Row {
            visible: root.activeTab === "search" && !root.detailOpen
            width: parent.width
            spacing: Style.space(8)

            TextField {
              id: searchField
              width: parent.width - searchButton.width - parent.spacing
              placeholderText: "Songs, artists, albums, playlists…"
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
              : root.loading
                ? "Loading…"
                : root.detailOpen
                  ? (root.detailLoaded
                    ? (root.detailKind === "album" ? "This album has no songs"
                      : root.detailKind === "artist" ? "This artist has no top songs"
                      : "This playlist has no songs")
                    : "Loading…")
                  : root.activeTab === "search"
                    ? (root.service.bridgeSearchTerm === "" ? "Search your catalog" : "No results")
                    : "Nothing here yet"
            color: Qt.darker(root.contentForeground, 1.4)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
            padding: Style.space(12)
          }

          // ---- One status line: a stalled bridge, or what the page refused.
          Row {
            visible: root.reconnecting || (root.service && root.service.bridgeError !== "")
            width: parent.width
            spacing: Style.space(8)

            Text {
              width: parent.width - (errorRetry.visible ? errorRetry.width + parent.spacing : 0)
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: root.reconnecting
                ? "Reconnecting to the player…"
                : (root.service ? root.service.bridgeError : "")
              color: root.reconnecting ? Qt.darker(root.contentForeground, 1.3) : Color.urgent
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Button {
              id: errorRetry
              visible: !root.reconnecting && root.service !== null
              anchors.verticalCenter: parent.verticalCenter
              text: "Retry"
              onClicked: root.detailOpen ? root.refreshDetail() : root.refreshData()
            }
          }

          // ---- Playlist drill-in header: back to the lists, and the name of
          //      the playlist whose songs are shown below.
          Row {
            visible: root.detailOpen
            width: parent.width
            spacing: Style.space(8)

            PanelActionButton {
              id: backButton
              anchors.verticalCenter: parent.verticalCenter
              iconText: "󰁍"
              tooltipText: "Back"
              onClicked: root.closeDetail()
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width - backButton.width - parent.spacing
              anchors.verticalCenter: parent.verticalCenter
              text: root.detailName !== ""
                ? root.detailName
                : (root.detailKind === "artist" ? "Artist"
                  : root.detailKind === "album" ? "Album" : "Playlist")
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.body
              font.bold: true
              elide: Text.ElideRight
            }
          }

        }

        // The song list gets its own scroller, sized to the room the card has
        // left, so scrolling search results or a playlist leaves the player in
        // place instead of sliding the whole panel.
        Flickable {
          id: listFlick
          width: parent.width
          height: root.listHeight
          contentWidth: width
          contentHeight: rowsColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          flickableDirection: Flickable.VerticalFlick
          interactive: contentHeight > height

          WheelHandler {
            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
            onWheel: function(event) {
              // One notch moves SCROLL_ROWS rows; a touchpad's pixel deltas get
              // the same multiplier, so the two feel alike.
              var dy = PanelModel.wheelScroll(event.pixelDelta.y, event.angleDelta.y,
                Style.space(44))
              listFlick.contentY = Math.max(0, Math.min(
                listFlick.contentHeight - listFlick.height,
                listFlick.contentY - dy))
              event.accepted = true
            }
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
                readonly property string rowKind: row ? String(row.kind || "") : ""
                readonly property bool rowActive: root.rowActive(row)
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
                      // Artists get a round avatar, the way Apple Music shows
                      // them, so an artist is obvious at a glance.
                      radius: rowEntry.rowKind === "artist" ? width / 2 : Style.cornerRadius * 0.6
                      anchors.verticalCenter: parent.verticalCenter
                      color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.08)

                      Text {
                        anchors.centerIn: parent
                        visible: thumb.status !== Image.Ready
                        text: rowEntry.rowKind === "artist"
                          ? "󰀄" : rowEntry.rowKind === "playlist" ? "󰲱" : "󰝚"
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
                      width: parent.width - Style.space(32) - Style.space(10) - playGlyphSlot.width - Style.space(10)
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: 1

                      Text {
                        textFormat: Text.PlainText
                        width: parent.width
                        text: rowEntry.row ? rowEntry.row.name : ""
                        color: rowEntry.rowActive ? Color.accent : root.contentForeground
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

                    // A fixed square slot keeps the hover glyph centered: the
                    // play and pause glyphs differ in width, so centering the
                    // icon inside a stable box is what holds it in the same
                    // place (and stops the title shifting) as it toggles.
                    Item {
                      id: playGlyphSlot
                      width: Math.max(Style.space(16), glyphMetrics.width)
                      height: width
                      anchors.verticalCenter: parent.verticalCenter

                      TextMetrics {
                        id: glyphMetrics
                        text: "󰏤"
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.icon
                      }

                      Text {
                        id: playGlyph
                        anchors.fill: parent
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        text: rowEntry.rowActive && root.playing ? "󰏤" : "󰐊"
                        opacity: rowEntry.rowActive || rowMouse.containsMouse ? 1.0 : 0.0
                        color: rowEntry.rowActive ? Color.accent : root.contentForeground
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.icon
                        Behavior on opacity { NumberAnimation { duration: 120 } }
                      }
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
        }

        Item { width: 1; height: Style.space(4) }
      }
    }
  }
}
