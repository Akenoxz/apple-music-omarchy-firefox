import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Services.Mpris
import qs.Commons
import "AppleMusicModel.js" as Model
import "PanelModel.js" as PanelModel

Item {
  id: root

  property var shell: null
  property var manifest: null

  // Third-party manifests omit host-private paths. Resolve bundled files
  // relative to this component, including percent-encoded installation paths.
  readonly property string sourceDir: decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "")).replace(/\/$/, "")
  readonly property string controlPath: sourceDir ? sourceDir + "/control.sh" : ""
  readonly property string rulesPath: sourceDir ? sourceDir + "/hypr/apple-music.lua" : ""

  property string windowAddress: ""
  property int browserPid: 0
  property bool opened: false
  property bool launching: false
  property bool rulesInstalled: false
  property string ownerScreen: ""
  property var lastAnchor: null
  property var monitors: []
  property bool dismissArmed: false
  property bool themeFocusLost: false
  property bool themePickerOpen: false
  property string pendingFocusAddress: ""
  property double themeFocusUntil: 0
  property string lastError: ""
  property bool themeReady: false
  property bool themeQueued: false
  property string themeError: ""
  property string themeRevision: ""
  property string publishedThemeSignature: ""
  property string publishingThemeSignature: ""

  readonly property string themeBackground: cssColor(Color.popups.background)
  readonly property string themeForeground: cssColor(Color.popups.text)
  readonly property string themeBorder: cssColor(Color.popups.border)
  readonly property string themeAccent: cssColor(Color.accent)
  readonly property string themeMuted: cssColor(Color.muted)
  readonly property string themeUrgent: cssColor(Color.urgent)
  readonly property string themeMode: colorLuminance(Color.popups.background) > 0.45 ? "light" : "dark"
  readonly property string themeSignature: [
    themeBackground,
    themeForeground,
    themeBorder,
    themeAccent,
    themeMuted,
    themeUrgent,
    themeMode
  ].join("|")

  readonly property var players: Mpris.players ? Mpris.players.values : []
  readonly property var activePlayer: Model.playerForPid(players, browserPid)
  readonly property bool hasMedia: activePlayer !== null
    && !!(activePlayer.trackTitle || activePlayer.trackArtist)
  readonly property string title: activePlayer ? String(activePlayer.trackTitle || "") : ""
  readonly property string artist: activePlayer ? String(activePlayer.trackArtist || "") : ""
  readonly property string album: activePlayer ? String(activePlayer.trackAlbum || "") : ""
  readonly property string artUrl: activePlayer ? String(activePlayer.trackArtUrl || "") : ""
  readonly property bool playing: activePlayer ? activePlayer.isPlaying === true : false
  readonly property bool spectrumWanted: opened && playing && browserPid > 0
  property int spectrumPid: 0

  // ---- Page bridge (bridge.mjs over WebDriver BiDi) -------------------------
  // bridge.mjs mirrors the signed-in Apple Music page into
  // $runtime/bridge/state.json and answers command files dropped into
  // $data/bridge-commands. Both go through control.sh so the widget behaves
  // the same in Chromium and Firefox modes.
  property bool bridgePolling: false
  property var bridgeState: PanelModel.normalizeState(null)
  property var bridgePlaylists: []
  property var bridgeCharts: []
  property var bridgeRecent: []
  property var bridgeSearchSections: []
  property string bridgeSearchTerm: ""
  // The tracks of the playlist the panel drilled into, plus the id they
  // belong to so a fresh reply can be told apart from the previous playlist.
  property var bridgePlaylistTracks: []
  property string bridgePlaylistId: ""
  // The artist profile the panel opened: identity plus their top songs and
  // albums, split so each section can be rendered on its own.
  property var bridgeArtistSongs: []
  property var bridgeArtistAlbums: []
  property string bridgeArtistId: ""
  property string bridgeArtistName: ""
  property string bridgeArtistArtwork: ""
  // Lyrics for the requested song, or null while none have been fetched. The
  // id lets the panel tell a stale reply from the song it is showing.
  property var bridgeLyrics: null
  property string bridgeLyricsId: ""
  property string bridgeError: ""

  // The panel reads that snapshot from the file itself, the way the rest of
  // the shell watches files: no process per update, and the view follows the
  // bridge's own cadence. control.sh resolves the same paths.
  readonly property string dataDir: (Quickshell.env("XDG_DATA_HOME") || Quickshell.env("HOME") + "/.local/share") + "/omarchy-apple-music"
  readonly property string runtimeDir: (Quickshell.env("XDG_RUNTIME_DIR") || root.dataDir + "/runtime") + "/omarchy-apple-music"
  readonly property string bridgeStatePath: root.runtimeDir + "/bridge/state.json"
  property double now: Date.now()
  // A snapshot older than a few poll ticks means the bridge stopped writing
  // (process gone, browser closed). The panel shows that as "reconnecting"
  // rather than freezing on the last known track.
  readonly property bool bridgeStale: bridgeState.ready === true
    && bridgeState.revision > 0 && root.now - bridgeState.revision > 4000
  // A list or search request is still on its way; the panel uses it to tell
  // "loading" apart from "nothing here".
  property bool bridgeLoading: false
  property var bridgeQueue: []
  property var bridgeCommandJob: null
  property string bridgeCommandOutput: ""

  property string stateIntent: ""
  property var stateAnchor: null
  property string stateOutput: ""
  property string queuedIntent: ""
  property var queuedAnchor: null
  property bool syncQueued: false
  property bool launchAfterRules: false
  property var rulesLaunchAnchor: null
  property bool forceRulesAfterCurrent: false
  property int launchAttempts: 0
  property var launchAnchor: null
  property string actionKind: ""
  property string initializedFor: ""

  function colorByte(value) {
    var byte = Math.max(0, Math.min(255, Math.round(Number(value) * 255)))
    var hex = byte.toString(16)
    return hex.length < 2 ? "0" + hex : hex
  }

  function cssColor(value) {
    return "#" + colorByte(value.r) + colorByte(value.g) + colorByte(value.b)
  }

  function colorChannelLuminance(value) {
    var channel = Number(value)
    return channel <= 0.04045 ? channel / 12.92 : Math.pow((channel + 0.055) / 1.055, 2.4)
  }

  function colorLuminance(value) {
    return 0.2126 * colorChannelLuminance(value.r)
      + 0.7152 * colorChannelLuminance(value.g)
      + 0.0722 * colorChannelLuminance(value.b)
  }

  function protectThemeFocus(duration) {
    var milliseconds = Math.max(0, Number(duration || 2000))
    themeFocusUntil = Math.max(themeFocusUntil, Date.now() + milliseconds)
  }

  function watchThemeTransition() {
    protectThemeFocus(2000)
    if (themeSettleProc.running || !controlPath) return
    themeSettleProc.command = [controlPath, "wait-theme"]
    themeSettleProc.running = true
  }

  function themeFocusProtected() {
    return themePickerOpen || themeSettleProc.running || Date.now() < themeFocusUntil
  }

  function syncTheme(force) {
    if (!controlPath) return
    if (themeProc.running) {
      themeQueued = true
      return
    }
    if (!force && themeSignature === publishedThemeSignature) return

    themeQueued = false
    themeError = ""
    themeRevision = ""
    publishingThemeSignature = themeSignature
    themeProc.command = [
      controlPath,
      "theme",
      themeBackground,
      themeForeground,
      themeBorder,
      themeAccent,
      themeMuted,
      themeUrgent,
      themeMode
    ]
    themeProc.running = true
  }

  function notifyFailure(message) {
    lastError = String(message || "Apple Music could not be opened")
    Quickshell.execDetached(["omarchy-notification-send", "Apple Music", lastError])
  }

  function requestState(intent, anchor) {
    var nextIntent = String(intent || "sync")
    if (stateProc.running) {
      if (nextIntent !== "sync") {
        queuedIntent = nextIntent
        queuedAnchor = anchor || lastAnchor
      } else {
        syncQueued = true
      }
      return
    }

    stateIntent = nextIntent
    stateAnchor = anchor || lastAnchor
    stateOutput = ""
    stateProc.command = [controlPath, "state"]
    stateProc.running = controlPath !== ""
  }

  function drainStateQueue() {
    if (queuedIntent !== "") {
      var intent = queuedIntent
      var anchor = queuedAnchor
      queuedIntent = ""
      queuedAnchor = null
      requestState(intent, anchor)
    } else if (syncQueued) {
      syncQueued = false
      requestState("sync", null)
    }
  }

  function syncState(state) {
    var client = state && state.client ? state.client : null
    monitors = state && Array.isArray(state.monitors) ? state.monitors : []
    windowAddress = client ? Model.normalizeAddress(client.address) : ""
    browserPid = client ? (parseInt(client.pid, 10) || 0) : 0
    if (client) lastError = ""
    opened = !!(state && state.open && windowAddress)
    if (opened && !dismissArmed) dismissDelay.restart()
    if (!opened) {
      dismissArmed = false
      dismissDelay.stop()
      dismissFocusDelay.stop()
      themeRefocusDelay.stop()
      themeFocusLost = false
      themePickerOpen = false
      pendingFocusAddress = ""
      themeFocusUntil = 0
    }
    ownerScreen = opened && state && state.openScreen ? String(state.openScreen) : ""
  }

  function handleState(raw, intent, anchor) {
    var state
    try {
      state = JSON.parse(String(raw || "{}"))
    } catch (error) {
      if (intent !== "sync" && intent !== "awaitLaunch")
        notifyFailure("Could not read the Hyprland window state")
      return
    }

    syncState(state)

    if (intent === "toggle") {
      if (opened) hide()
      else if (state.client) showExisting(state.client, state.monitors, anchor)
      else launch(anchor)
    } else if (intent === "show") {
      if (state.client) showExisting(state.client, state.monitors, anchor)
      else launch(anchor)
    } else if (intent === "awaitLaunch") {
      if (state.client) {
        launchPoll.stop()
        launching = false
        showExisting(state.client, state.monitors, launchAnchor)
      }
    }
  }

  function launch(anchor) {
    if (launching || launchProc.running) return
    if (!rulesInstalled) {
      launchAfterRules = true
      rulesLaunchAnchor = anchor || lastAnchor
      // A failed eval can leave the Lua guard set even though no rule exists.
      // Force the retry so the pending launch cannot accept that stale guard.
      installRules(true)
      return
    }
    syncTheme(false)
    launching = true
    lastError = ""
    launchAttempts = 0
    launchAnchor = anchor || lastAnchor
    launchProc.command = [controlPath, "launch"]
    launchProc.running = true
  }

  function showExisting(client, availableMonitors, anchor) {
    var actualAnchor = anchor || lastAnchor || ({
      screenName: "",
      x: 0,
      y: 0,
      width: 1,
      height: 1,
      barPosition: "top"
    })
    var monitor = Model.monitorFor(availableMonitors, actualAnchor.screenName)
    var desiredSize = Model.dropdownSize(client)
    var rect = Model.placement(actualAnchor, monitor, desiredSize.width, desiredSize.height, 12)
    var address = Model.normalizeAddress(client && client.address)
    if (!monitor || !rect || !address) {
      notifyFailure("Could not place the Apple Music window")
      return
    }

    lastAnchor = actualAnchor
    windowAddress = address
    browserPid = parseInt(client.pid, 10) || 0
    ownerScreen = String(monitor.name || actualAnchor.screenName || "")
    dismissArmed = false
    actionKind = "show"
    actionProc.command = [
      controlPath, "show", address, ownerScreen,
      String(rect.x), String(rect.y), String(rect.width), String(rect.height)
    ]
    actionProc.running = true
  }

  function show(anchor) {
    if (anchor) lastAnchor = anchor
    requestState("show", anchor || lastAnchor)
  }

  function hide() {
    if ((!opened && !windowAddress) || actionProc.running) return
    dismissArmed = false
    dismissFocusDelay.stop()
    pendingFocusAddress = ""
    actionKind = "hide"
    actionProc.command = [controlPath, "hide", windowAddress]
    actionProc.running = true
  }

  function toggle(anchor) {
    if (anchor) lastAnchor = anchor
    requestState("toggle", anchor || lastAnchor)
  }

  function runAction(action) {
    var player = activePlayer
    if (!player) return false

    if (action === "next" && player.canGoNext) {
      player.next()
      return true
    }
    if (action === "previous" && player.canGoPrevious) {
      player.previous()
      return true
    }
    if (action === "playPause") {
      if (player.isPlaying && player.canPause) player.pause()
      else if (!player.isPlaying && player.canPlay) player.play()
      else if (player.canTogglePlaying) player.togglePlaying()
      else return false
      return true
    }
    return false
  }

  function refreshBridgeState() {
    bridgeStateFile.reload()
  }

  function setBridgePolling(on) {
    bridgePolling = !!on
    if (bridgePolling) refreshBridgeState()
  }

  // One queue for transport commands and list queries alike, so a flurry of
  // clicks can never interleave two bridge replies.
  function runBridge(op, args, kind) {
    if (!controlPath) return false
    var job = { op: String(op || ""), args: args || {}, kind: String(kind || "") }
    bridgeQueue.push(job)
    if (job.kind !== "") bridgeLoading = true
    drainBridgeQueue()
    return true
  }

  function drainBridgeQueue() {
    if (bridgeCommandProc.running || bridgeQueue.length === 0) return
    var job = bridgeQueue.shift()
    bridgeCommandJob = job
    bridgeCommandOutput = ""
    bridgeCommandProc.command = [controlPath, "bridge", PanelModel.commandJson(job.op, job.args)]
    bridgeCommandProc.running = true
  }

  function applyBridgeReply(job, reply) {
    if (!job) return
    if (!reply || reply.ok !== true) {
      bridgeError = reply && reply.error ? String(reply.error) : "The page bridge did not answer"
      return
    }
    bridgeError = ""
    if (job.kind === "playlists") {
      bridgePlaylists = PanelModel.normalizeRows(reply.data, "playlist")
    } else if (job.kind === "charts") {
      bridgeCharts = PanelModel.normalizeRows(reply.data, "playlist")
    } else if (job.kind === "recentlyAdded") {
      bridgeRecent = PanelModel.normalizeRows(reply.data, "album")
    } else if (job.kind === "browse") {
      var lists = PanelModel.browseLists(reply.data)
      bridgePlaylists = lists.playlists
      bridgeRecent = lists.recent
      bridgeCharts = lists.charts
    } else if (job.kind === "search") {
      bridgeSearchSections = PanelModel.searchSections(reply.data)
      bridgeSearchTerm = job.args && job.args.term ? String(job.args.term) : ""
    } else if (job.kind === "playlistTracks") {
      bridgePlaylistTracks = PanelModel.normalizeRows(reply.data, "song")
      bridgePlaylistId = job.args && job.args.id ? String(job.args.id) : ""
    } else if (job.kind === "artistDetail") {
      var artist = PanelModel.artistDetail(reply.data)
      bridgeArtistSongs = artist.songs
      bridgeArtistAlbums = artist.albums
      bridgeArtistId = artist.id
      bridgeArtistName = artist.name
      bridgeArtistArtwork = artist.artwork
    } else if (job.kind === "lyrics") {
      bridgeLyrics = reply.data && typeof reply.data === "object" ? reply.data : null
      bridgeLyricsId = job.args && job.args.id ? String(job.args.id) : ""
    }
  }

  function installRules(force) {
    if (!controlPath || !rulesPath) return
    if (rulesProc.running) {
      if (force) forceRulesAfterCurrent = true
      return
    }
    rulesProc.command = [controlPath, "rules", rulesPath, force ? "true" : "false"]
    rulesProc.running = true
  }

  function syncSpectrum() {
    spectrumRestart.stop()
    if (!spectrumWanted) {
      if (spectrumProc.running) spectrumProc.running = false
      else spectrumPid = 0
      return
    }

    if (spectrumProc.running) {
      if (spectrumPid !== browserPid) spectrumProc.running = false
      return
    }

    spectrumPid = browserPid
    spectrumProc.command = [controlPath, "spectrum", String(browserPid)]
    spectrumProc.running = true
  }

  function handleHyprlandEvent(event) {
    var name = String(event && event.name ? event.name : "")
    if (name === "openlayer") {
      var openedLayer = String(Model.eventParts(event, 1)[0] || "")
      if (openedLayer === "omarchy-image-selector") {
        themePickerOpen = true
        themeFocusLost = opened
        dismissFocusDelay.stop()
        pendingFocusAddress = ""
      }
      return
    }

    if (name === "closelayer") {
      var closedLayer = String(Model.eventParts(event, 1)[0] || "")
      if (closedLayer === "omarchy-image-selector" && themePickerOpen) {
        themePickerOpen = false
        if (opened) {
          watchThemeTransition()
          themeRefocusDelay.restart()
        }
      }
      return
    }

    if (name === "configreloaded") {
      rulesInstalled = false
      ruleReload.restart()
      return
    }

    if (name === "openwindow" || name === "activespecial") {
      requestState("sync", null)
      return
    }

    if (name === "closewindow") {
      var closed = Model.normalizeAddress(Model.eventParts(event, 1)[0])
      if (closed && closed === windowAddress) {
        windowAddress = ""
        browserPid = 0
        opened = false
        ownerScreen = ""
        dismissArmed = false
        dismissFocusDelay.stop()
        themeRefocusDelay.stop()
        themeFocusLost = false
        themePickerOpen = false
        pendingFocusAddress = ""
        themeFocusUntil = 0
      }
      return
    }

    if (name === "activewindowv2" && dismissArmed) {
      var focused = Model.normalizeAddress(Model.eventParts(event, 1)[0])
      var disposition = Model.focusDisposition(
        opened,
        focused,
        windowAddress,
        themeFocusProtected()
      )
      if (disposition === "restore") {
        dismissFocusDelay.stop()
        pendingFocusAddress = ""
        themeFocusLost = true
        protectThemeFocus(12000)
        if (!themePickerOpen) themeRefocusDelay.restart()
      } else if (disposition === "dismiss") {
        pendingFocusAddress = focused
        dismissFocusDelay.restart()
      } else {
        dismissFocusDelay.stop()
        pendingFocusAddress = ""
        themeFocusLost = false
      }
    }
  }

  function initialize() {
    if (!controlPath || !rulesPath || initializedFor === sourceDir) return
    initializedFor = sourceDir
    syncTheme(true)
    installRules(false)
    requestState("sync", null)
  }

  // The manifest updates both derived paths, but their bindings are not
  // guaranteed to settle in the same turn. Defer and listen to both so an
  // early controlPath change cannot permanently skip rule installation.
  onControlPathChanged: Qt.callLater(root.initialize)
  onRulesPathChanged: Qt.callLater(root.initialize)
  onSpectrumWantedChanged: spectrumSync.restart()
  onBrowserPidChanged: spectrumSync.restart()

  Component.onCompleted: Qt.callLater(function() {
    root.initialize()
  })

  Process {
    id: themeProc
    stdout: StdioCollector {
      onStreamFinished: root.themeRevision = String(text || "").trim()
    }
    onExited: function(code) {
      var shouldRepeat = root.themeQueued
        || root.themeSignature !== root.publishingThemeSignature
      if (code === 0) {
        root.themeReady = true
        root.themeError = ""
        root.publishedThemeSignature = root.publishingThemeSignature
      } else {
        root.themeReady = false
        root.themeError = "Could not publish the Omarchy palette"
        console.warn("apple-music: could not publish browser theme")
      }
      root.publishingThemeSignature = ""
      if (shouldRepeat) {
        root.themeQueued = false
        Qt.callLater(function() { root.syncTheme(false) })
      }
    }
  }

  Process {
    id: spectrumProc
    onExited: function(code) {
      root.spectrumPid = 0
      if (root.spectrumWanted) spectrumRestart.restart()
    }
  }

  Timer {
    id: spectrumSync
    interval: 0
    onTriggered: root.syncSpectrum()
  }

  Timer {
    id: spectrumRestart
    interval: 500
    onTriggered: root.syncSpectrum()
  }

  Timer {
    id: themeDebounce
    interval: 25
    onTriggered: root.syncTheme(false)
  }

  onThemeSignatureChanged: {
    themeDebounce.restart()
    if (opened) {
      watchThemeTransition()
      if (themeFocusLost && !themePickerOpen) themeRefocusDelay.restart()
    }
  }

  Timer {
    id: themeRefocusDelay
    interval: 350
    onTriggered: {
      if (!root.themeFocusLost || !root.opened || !root.windowAddress) {
        root.themeFocusLost = false
        return
      }
      root.themeFocusLost = false
      themeRefocusProc.command = [root.controlPath, "focus", root.windowAddress]
      themeRefocusProc.running = true
    }
  }

  Process {
    id: themeSettleProc
    onExited: {
      root.protectThemeFocus(12000)
      if (root.themeFocusLost && root.opened) themeRefocusDelay.restart()
    }
  }

  Process {
    id: themeRefocusProc
    onExited: function(code) {
      if (code !== 0) console.warn("apple-music: could not restore focus after theme change")
    }
  }

  FileView {
    id: bridgeStateFile
    path: root.bridgeStatePath
    watchChanges: true
    printErrors: false
    // text() is stale inside the change signal itself, so reload and parse in
    // onLoaded — the same pattern the shell uses for watched config files.
    onLoaded: root.bridgeState = PanelModel.normalizeState(text())
    onFileChanged: bridgeStateFile.reload()
    onLoadFailed: root.bridgeState = PanelModel.normalizeState(null)
  }

  // FileView cannot observe a file that does not exist yet, so until the
  // bridge has published a snapshot, check again at a human pace.
  Timer {
    interval: 1000
    repeat: true
    running: root.bridgeState.ready !== true
    onTriggered: bridgeStateFile.reload()
  }

  Timer {
    id: clock
    interval: 1000
    repeat: true
    running: true
    onTriggered: root.now = Date.now()
  }

  Process {
    id: bridgeCommandProc
    stdout: StdioCollector {
      onStreamFinished: root.bridgeCommandOutput = String(text || "")
    }
    onExited: function(code) {
      var job = root.bridgeCommandJob
      root.bridgeCommandJob = null
      var reply = null
      try {
        reply = JSON.parse(root.bridgeCommandOutput)
      } catch (error) {
        reply = null
      }
      root.applyBridgeReply(job, reply)
      root.bridgeLoading = root.bridgeQueue.some(function(j) { return j.kind !== "" })
      Qt.callLater(root.drainBridgeQueue)
    }
  }

  Process {
    id: stateProc
    stdout: StdioCollector {
      onStreamFinished: root.stateOutput = text
    }
    onExited: function(code) {
      var intent = root.stateIntent
      var anchor = root.stateAnchor
      root.stateIntent = ""
      root.stateAnchor = null
      if (code === 0) root.handleState(root.stateOutput, intent, anchor)
      else if (intent !== "sync" && intent !== "awaitLaunch")
        root.notifyFailure("Hyprland is not available")
      Qt.callLater(root.drainStateQueue)
    }
  }

  Process {
    id: launchProc
    onExited: function(code) {
      if (code !== 0) {
        root.launching = false
        root.notifyFailure("Could not launch the configured browser")
        return
      }
      launchPoll.restart()
    }
  }

  Timer {
    id: launchPoll
    interval: 250
    repeat: true
    onTriggered: {
      // Timeout lives here so it fires even when `control.sh state` keeps failing.
      if (root.launchAttempts >= 40) {
        launchPoll.stop()
        root.launching = false
        root.notifyFailure("The browser did not create the Apple Music window")
        return
      }
      root.launchAttempts++
      root.requestState("awaitLaunch", root.launchAnchor)
    }
  }

  Process {
    id: actionProc
    onExited: function(code) {
      if (code !== 0) {
        root.notifyFailure(root.actionKind === "hide"
          ? "Could not hide the Apple Music window"
          : "Could not position the Apple Music window")
      } else {
        root.lastError = ""
        if (root.actionKind === "show") {
          root.opened = true
          dismissDelay.restart()
        } else if (root.actionKind === "hide") {
          root.opened = false
          root.ownerScreen = ""
        }
      }
      root.actionKind = ""
      stateRefresh.restart()
    }
  }

  Timer {
    id: dismissDelay
    interval: 350
    onTriggered: root.dismissArmed = root.opened
  }

  Timer {
    id: dismissFocusDelay
    interval: 140
    onTriggered: {
      if (root.themeFocusProtected()) {
        root.themeFocusLost = root.opened
        root.protectThemeFocus(12000)
        if (!root.themePickerOpen) themeRefocusDelay.restart()
      } else if (Model.shouldDismissWindow(
        root.opened,
        root.pendingFocusAddress,
        root.windowAddress
      )) {
        root.hide()
      }
      root.pendingFocusAddress = ""
    }
  }

  Timer {
    id: stateRefresh
    interval: 250
    onTriggered: root.requestState("sync", null)
  }

  Process {
    id: rulesProc
    onExited: function(code) {
      var forceAgain = root.forceRulesAfterCurrent
      root.forceRulesAfterCurrent = false

      if (forceAgain) {
        root.rulesInstalled = false
        if (code !== 0)
          console.warn("apple-music: initial runtime window rule install failed; retrying")
        Qt.callLater(function() { root.installRules(true) })
        return
      }

      root.rulesInstalled = code === 0
      if (code !== 0) {
        console.warn("apple-music: could not install runtime window rules")
        if (root.launchAfterRules)
          root.notifyFailure("Could not prepare the Apple Music dropdown")
        root.launchAfterRules = false
        root.rulesLaunchAnchor = null
        return
      }

      if (root.launchAfterRules) {
        var anchor = root.rulesLaunchAnchor
        root.launchAfterRules = false
        root.rulesLaunchAnchor = null
        Qt.callLater(function() { root.launch(anchor) })
      }
    }
  }

  Timer {
    id: ruleReload
    interval: 400
    onTriggered: root.installRules(true)
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) { root.handleHyprlandEvent(event) }
  }

  IpcHandler {
    target: "apple-music"

    function open(): string { root.show(root.lastAnchor); return "ok" }
    function close(): string { root.hide(); return "ok" }
    function show(): string { root.show(root.lastAnchor); return "ok" }
    function hide(): string { root.hide(); return "ok" }
    function toggle(): string { root.toggle(root.lastAnchor); return "ok" }
    function playPause(): string { return root.runAction("playPause") ? "ok" : "unavailable" }
    function next(): string { return root.runAction("next") ? "ok" : "unavailable" }
    function previous(): string { return root.runAction("previous") ? "ok" : "unavailable" }
    function refreshTheme(): string { root.syncTheme(true); return "ok" }
    function ping(): string { return "ok" }

    function status(): string {
      return JSON.stringify({
        windowAddress: root.windowAddress,
        browserPid: root.browserPid,
        opened: root.opened,
        launching: root.launching,
        ownerScreen: root.ownerScreen,
        rulesInstalled: root.rulesInstalled,
        hasMedia: root.hasMedia,
        playing: root.playing,
        spectrumWanted: root.spectrumWanted,
        spectrumRunning: spectrumProc.running,
        title: root.title,
        artist: root.artist,
        themeReady: root.themeReady,
        themeMode: root.themeMode,
        themeRevision: root.themeRevision,
        themeError: root.themeError,
        lastError: root.lastError,
        bridgeReady: root.bridgeState.ready === true,
        bridgeStale: root.bridgeStale,
        bridgeLoading: root.bridgeLoading,
        sourceDir: root.sourceDir
      })
    }
  }
}
