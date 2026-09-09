import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  property var shell: null
  property var manifest: null
  property var pluginRegistry: null

  readonly property string pluginId: "io.github.odessa2.bing-wallpaper"
  readonly property string home: Quickshell.env("HOME")
  readonly property string cacheHome: Quickshell.env("XDG_CACHE_HOME") || home + "/.cache"
  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || home + "/.local/state"
  readonly property string imagesDir: cacheHome + "/omarchy/bing-wallpaper"
  readonly property string backgroundLink: stateHome + "/omarchy/current/background"
  readonly property string themeNamePath: stateHome + "/omarchy/current/theme.name"
  property int lastExitCode: -1
  property string lastError: ""
  property string lastRunAt: ""
  property string market: "auto"
  property string effectiveMarket: "en-US"
  property bool setWallpaper: true
  property var currentImage: null
  property bool settingsReady: false
  property string settingsSource: "defaults"
  property bool legacyConfigurationLoaded: false
  property bool legacyConfigFound: false
  property string legacyMarket: "auto"
  property bool legacySetWallpaper: true
  property string legacyStatusText: ""
  property bool refreshPending: false
  property string currentBackground: ""
  readonly property bool ownsBackground: isPluginBackground(currentBackground)
  property bool ownershipEstablished: false
  property string themeName: ""
  property string reapplyFile: ""
  property bool themeTransitionActive: false
  readonly property bool busy: updateProcess.running

  // The host strips __sourceDir from third-party manifests, so the plugin
  // directory is resolved from the registry's entry point URL. The manifest is
  // only a fallback for first-party hosts that still expose the field.
  function decodeFileUrl(url) {
    var text = String(url || "")
    if (text.indexOf("file://") !== 0) return ""
    var segments = text.slice(7).split("/")
    var decoded = []
    for (var i = 0; i < segments.length; i++) {
      try {
        decoded.push(decodeURIComponent(segments[i]))
      } catch (error) {
        return ""
      }
    }
    return decoded.join("/")
  }

  function parentDirectory(path) {
    var text = String(path || "")
    var index = text.lastIndexOf("/")
    return index > 0 ? text.slice(0, index) : ""
  }

  readonly property string serviceEntryPath: pluginRegistry && manifest
      && typeof pluginRegistry.entryPointUrl === "function"
    ? decodeFileUrl(pluginRegistry.entryPointUrl(manifest, "service"))
    : ""
  readonly property string sourceDir: serviceEntryPath !== ""
    ? parentDirectory(serviceEntryPath)
    : (manifest && manifest.__sourceDir ? String(manifest.__sourceDir) : "")
  readonly property string helperPath: sourceDir !== ""
    ? sourceDir + "/scripts/update-wallpaper"
    : ""

  function validMarket(value) {
    var candidate = String(value || "")
    return candidate === "auto"
      || candidate === "global"
      || /^[a-z]{2}-[A-Z]{2}$/.test(candidate)
  }

  // Third-party plugins receive only the bar section of the shell
  // configuration, so fall back to it when the full config is unavailable.
  function barLayout() {
    var config = shell && shell.shellConfig ? shell.shellConfig : null
    if (config && config.bar && config.bar.layout) return config.bar.layout
    var barConfig = shell && shell.barConfig ? shell.barConfig : null
    return barConfig && barConfig.layout ? barConfig.layout : null
  }

  function inlineEntry() {
    var config = shell && shell.shellConfig ? shell.shellConfig : null
    var layout = barLayout()
    if (layout) {
      var sections = ["left", "center", "right"]
      for (var s = 0; s < sections.length; s++) {
        var entries = layout[sections[s]]
        if (!entries || typeof entries.length !== "number") continue
        for (var i = 0; i < entries.length; i++) {
          var entry = entries[i]
          if (entry && String(entry.id || "") === pluginId) return entry
        }
      }
    }

    var plugins = config && config.plugins
    if (plugins && typeof plugins.length === "number") {
      for (var p = 0; p < plugins.length; p++) {
        var plugin = plugins[p]
        if (plugin && String(plugin.id || "") === pluginId) return plugin
      }
    }
    return null
  }

  function hasInlineConfiguration(entry) {
    return !!entry && (entry.market !== undefined || entry.setWallpaper !== undefined)
  }

  function applyConfiguration(nextMarket, nextSetWallpaper, source) {
    var normalizedMarket = validMarket(nextMarket) ? String(nextMarket) : "auto"
    var normalizedSetWallpaper = nextSetWallpaper !== false
    var changed = market !== normalizedMarket || setWallpaper !== normalizedSetWallpaper
    market = normalizedMarket
    setWallpaper = normalizedSetWallpaper
    if (!normalizedSetWallpaper) ownershipEstablished = false
    settingsSource = source || settingsSource
    settingsReady = true
    return changed
  }

  function setConfiguration(nextMarket, nextSetWallpaper) {
    applyConfiguration(nextMarket, nextSetWallpaper, "shell")
  }

  function isPluginBackground(path) {
    var candidate = String(path || "")
    return candidate !== "" && candidate.indexOf(imagesDir + "/") === 0
  }

  function disableWallpaperApplication() {
    if (!setWallpaper) return

    var existing = inlineEntry()
    var entry = { id: pluginId }
    if (existing) {
      for (var key in existing) if (key !== "id") entry[key] = existing[key]
    }
    entry.market = market
    entry.setWallpaper = false

    applyConfiguration(market, false, "shell")
    if (shell && typeof shell.updateEntryInline === "function") {
      if (!shell.updateEntryInline(pluginId, entry))
        console.warn("bing-wallpaper: could not persist automatic setWallpaper=false")
    } else {
      console.warn("bing-wallpaper: shell cannot persist automatic setWallpaper=false")
    }
  }

  function adoptBackgroundPath(path) {
    var candidate = String(path || "").trim()
    currentBackground = candidate

    if (isPluginBackground(candidate)) {
      if (setWallpaper) ownershipEstablished = true
      return
    }

    if (setWallpaper && ownershipEstablished && !themeTransitionActive) {
      console.log("bing-wallpaper: manual background change detected; disabling wallpaper application")
      disableWallpaperApplication()
    }
  }

  function refreshBackgroundPath() {
    if (!backgroundPathProcess.running) backgroundPathProcess.running = true
  }

  function onThemeNameRead(name) {
    var nextName = String(name || "").trim()
    var previousName = themeName
    themeName = nextName
    if (previousName === "" || previousName === nextName) return

    themeSettleTimer.restart()
    if (!setWallpaper || !ownershipEstablished || !ownsBackground) return

    reapplyFile = currentBackground
    themeTransitionActive = true
    reapplyTimer.restart()
  }

  function syncConfigurationFromShell() {
    if (helperPath === "" || !shell) return
    var entry = inlineEntry()
    if (hasInlineConfiguration(entry)) {
      var wasReady = settingsReady
      var changed = applyConfiguration(
        entry.market !== undefined ? entry.market : "auto",
        entry.setWallpaper !== undefined ? entry.setWallpaper : true,
        "shell")
      if (wasReady && changed) refresh()
      else loadStatus()
      return
    }

    if (!legacyConfigurationLoaded && !legacyStatusProcess.running) {
      settingsReady = false
      legacyStatusText = ""
      legacyStatusProcess.command = [helperPath, "legacy-status"]
      legacyStatusProcess.running = true
      return
    }

    if (legacyConfigurationLoaded) {
      var wasReady = settingsReady
      var changed = applyConfiguration(
        legacyConfigFound ? legacyMarket : "auto",
        legacyConfigFound ? legacySetWallpaper : true,
        legacyConfigFound ? "legacy" : "defaults")
      if (wasReady && changed) refresh()
      else loadStatus()
    }
  }

  function applyLegacyConfiguration(raw, exitCode) {
    legacyConfigurationLoaded = true
    var nextMarket = "auto"
    var nextSetWallpaper = true
    var source = "defaults"

    if (exitCode === 0) {
      try {
        var data = JSON.parse(String(raw || "{}"))
        if (data.legacyConfigFound === true) {
          nextMarket = data.market
          nextSetWallpaper = data.setWallpaper
          source = "legacy"
          legacyConfigFound = true
        }
        effectiveMarket = String(data.effectiveMarket || effectiveMarket)
        currentImage = data.current || null
      } catch (error) {
        console.warn("bing-wallpaper: invalid legacy status:", error)
      }
    }

    legacyMarket = validMarket(nextMarket) ? String(nextMarket) : "auto"
    legacySetWallpaper = nextSetWallpaper !== false

    if (!hasInlineConfiguration(inlineEntry()))
      applyConfiguration(legacyMarket, legacySetWallpaper, source)
    else
      syncConfigurationFromShell()
  }

  function refresh() {
    if (helperPath === "" || !settingsReady) return
    if (updateProcess.running) {
      refreshPending = true
      return
    }
    lastError = ""
    updateProcess.command = [
      helperPath,
      "update",
      market,
      setWallpaper ? "true" : "false"
    ]
    updateProcess.running = true
  }

  function loadStatus() {
    if (helperPath === "" || !settingsReady || statusProcess.running) return
    statusProcess.command = [
      helperPath,
      "status",
      market,
      setWallpaper ? "true" : "false"
    ]
    statusProcess.running = true
  }

  function applyStatus(raw) {
    try {
      var data = JSON.parse(String(raw || "{}"))
      effectiveMarket = String(data.effectiveMarket || "en-US")
      currentImage = data.current || null
    } catch (error) {
      console.warn("bing-wallpaper: invalid status:", error)
    }
  }

  Process {
    id: updateProcess

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.lastError = String(text || "").trim()
    }

    onExited: function(exitCode) {
      root.lastExitCode = exitCode
      root.lastRunAt = new Date().toISOString()
      if (exitCode !== 0 && root.lastError !== "")
        console.warn("bing-wallpaper:", root.lastError)
      if (exitCode === 0 && root.setWallpaper)
        root.refreshBackgroundPath()
      if (root.refreshPending) {
        root.refreshPending = false
        root.refresh()
      } else {
        root.loadStatus()
      }
    }
  }

  Process {
    id: statusProcess

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyStatus(text)
    }
  }

  Process {
    id: legacyStatusProcess

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.legacyStatusText = String(text || "")
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var message = String(text || "").trim()
        if (message !== "") console.warn("bing-wallpaper:", message)
      }
    }

    onExited: function(exitCode) {
      root.applyLegacyConfiguration(root.legacyStatusText, exitCode)
    }
  }

  Process {
    id: backgroundPathProcess
    command: ["readlink", "-f", root.backgroundLink]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.adoptBackgroundPath(text)
    }
  }

  Process {
    id: reapplyProcess

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var message = String(text || "").trim()
        if (message !== "") console.warn("bing-wallpaper:", message)
      }
    }

    onExited: function(exitCode) {
      if (exitCode !== 0)
        console.warn("bing-wallpaper: could not restore the wallpaper after the theme change")
      root.reapplyFile = ""
      root.themeTransitionActive = false
      root.refreshBackgroundPath()
    }
  }

  FileView {
    id: themeView
    path: root.themeNamePath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.onThemeNameRead(text())
    onLoadFailed: root.themeName = ""
  }

  Timer {
    interval: 60 * 60 * 1000
    running: root.helperPath !== "" && root.settingsReady
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    interval: 60 * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshBackgroundPath()
  }

  Timer {
    id: themeSettleTimer
    interval: 2500
    repeat: false
    onTriggered: root.refreshBackgroundPath()
  }

  Timer {
    id: reapplyTimer
    interval: 1800
    repeat: false
    onTriggered: {
      if (root.reapplyFile === "") {
        root.themeTransitionActive = false
        return
      }
      reapplyProcess.command = ["omarchy", "theme", "bg", "set", root.reapplyFile]
      reapplyProcess.running = true
    }
  }

  Connections {
    target: root.shell
    function onBarConfigChanged() { root.syncConfigurationFromShell() }
  }

  onShellChanged: syncConfigurationFromShell()
  onHelperPathChanged: syncConfigurationFromShell()
  onPluginRegistryChanged: syncConfigurationFromShell()

  IpcHandler {
    target: "bing-wallpaper"

    function refresh(): string {
      if (!root.settingsReady) return "settings not ready"
      if (updateProcess.running) return "already running"
      root.refresh()
      return "refresh started"
    }

    function status(): string {
      return JSON.stringify({
        running: updateProcess.running,
        refreshPending: root.refreshPending,
        market: root.market,
        effectiveMarket: root.effectiveMarket,
        setWallpaper: root.setWallpaper,
        settingsReady: root.settingsReady,
        settingsSource: root.settingsSource,
        currentImage: root.currentImage,
        currentBackground: root.currentBackground,
        ownsBackground: root.ownsBackground,
        ownershipEstablished: root.ownershipEstablished,
        themeTransitionActive: root.themeTransitionActive,
        lastExitCode: root.lastExitCode,
        lastError: root.lastError,
        lastRunAt: root.lastRunAt
      })
    }
  }
}
