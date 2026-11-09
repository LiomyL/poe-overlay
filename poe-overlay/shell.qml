import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Window
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "route_progress.js" as RouteProgress

// Campaign route HUD backed by the local Path of Exile log.
ShellRoot {
    id: root

    readonly property string appDir: Quickshell.shellDir
    readonly property string stateDir: Quickshell.env("POE_OVERLAY_STATE_DIR")
        || (Quickshell.env("XDG_STATE_HOME")
            ? Quickshell.env("XDG_STATE_HOME") + "/poe-overlay"
            : Quickshell.env("HOME") + "/.local/state/poe-overlay")
    readonly property string pythonPath: Quickshell.env("POE_OVERLAY_PYTHON") || "python3"
    property string logPath: Quickshell.env("POE_CLIENT_LOG")
        || Quickshell.env("HOME") + "/.local/share/Steam/steamapps/common/Path of Exile/logs/Client.txt"
    property string areasPath: Qt.resolvedUrl("routes/areas.json")
    property string routePath: appDir + "/routes"
    property string routeParserPath: appDir + "/load_route.py"
    property string gemsPath: Qt.resolvedUrl("routes/gems.json")
    property string questsPath: Qt.resolvedUrl("routes/quests.json")
    property string charactersPath: Qt.resolvedUrl("routes/characters.json")
    property string vaalGemLookupPath: Qt.resolvedUrl("routes/vaal-gem-lookup.json")
    property string awakenedGemLookupPath: Qt.resolvedUrl("routes/awakened-gem-lookup.json")
    property string parserPath: appDir + "/import_pob.py"
    property string routeStatePath: appDir + "/route_state.py"
    property string buildStatePath: stateDir + "/build.json"
    property string hudStatePath: stateDir + "/overlay_state.json"
    property string routeCheckpointPath: stateDir + "/route_checkpoint.json"
    property string hudGeometryPath: "/tmp/poe-overlay-hud-geometry"

    property string zone: "Waiting for area..."
    property string areaId: ""
    property string previousAreaId: ""
    property string routeMode: "leaguestart"
    property var routeData: null
    property var staticJsonCache: ({})
    property bool routeLoadPending: false
    property bool routePausedForDetour: false
    property string recoveryTargetAreaId: ""
    property bool routeCheckpointLoaded: false
    property bool routeCheckpointValid: false
    property bool routeCheckpointResponseReceived: false
    property bool routeLogStarted: false
    property bool routeReplayPending: false
    property var bufferedLiveRouteLines: []
    property bool savedBuildReady: false
    property bool routeCheckpointSavePending: false
    property bool routeCheckpointClearPending: false
    property bool routeCheckpointSelectionPending: false
    property bool routeCheckpointResetRequested: false
    property var loadedRouteCheckpoint: null
    property string pendingRouteCheckpoint: ""
    property string checkpointLogStamp: ""
    property string pendingGeneratedAreaId: ""
    property var routeItems: []
    property var routeSections: []
    property var collapsedActs: ({})
    property int autoRouteAct: -1
    property int autoRouteStep: -1
    property var buildData: null
    property string importStatus: ""
    property string pendingBuildCode: ""
    property string pendingBuildState: ""
    property string pendingHudState: ""
    property bool buildStateSavePending: false
    property bool hudStateSavePending: false
    property bool importResponseReceived: false
    property bool overlayVisible: true
    property bool hudEnabled: true
    property bool buildViewerVisible: false
    property bool routeSettingsLoaded: false
    property string manualBandit: "auto"
    property int settingsTab: 0
    property string lastHudState: ""
    readonly property var banditOptions: [
        { value: "auto", label: "Use PoB selection", description: "Follow the imported build; without a build, choose Eramir." },
        { value: "none", label: "Choose Eramir", description: "Kill all three bandits to gain 1 Passive Skill Point." },
        { value: "oak", label: "Help Oak", description: "+40 to maximum Life." },
        { value: "kraityn", label: "Help Kraityn", description: "8% increased Movement Speed." },
        { value: "alira", label: "Help Alira", description: "+15% to all Elemental Resistances." }
    ]

    readonly property string effectiveBandit: manualBandit === "auto"
        ? (buildData && buildData.bandit ? buildData.bandit.toLowerCase() : "none")
        : manualBandit
    readonly property string effectiveBanditDescription: banditOptions.find(option => option.value === effectiveBandit).description

    onRouteModeChanged: loadRouteData()

    function loadRouteData() {
        if (routeLoadProcess.running) {
            routeLoadPending = true
            return
        }
        const bandit = effectiveBandit
        routeLoadProcess.command = [pythonPath, routeParserPath, routePath, routeMode, bandit, "true"]
        routeLoadProcess.running = true
    }

    function handleRouteLoad(data) {
        try {
            const result = JSON.parse(data)
            if (result.error)
                throw new Error(result.error)
            const routeConfigChanged = routeData && (
                routeData.fingerprint !== result.fingerprint
                || routeData.mode !== result.mode
                || routeData.bandit !== result.bandit
            )
            if (routeLogStarted && routeConfigChanged) {
                autoRouteAct = -1
                autoRouteStep = -1
                recoveryTargetAreaId = ""
            }
            routeData = result
            tryStartRouteLog()
            updateRouteGoal()
            if (routeLogStarted && !routeConfigChanged && checkpointLogStamp)
                saveRouteCheckpoint(checkpointLogStamp)
        } catch (error) {
            routeData = null
            routeItems = [{ html: "Could not load route files", hint: false, optional: false }]
            console.warn("Could not load route files:", error)
        }
    }

    function loadRouteCheckpoint() {
        routeCheckpointLoadProcess.command = [pythonPath, routeStatePath, "--read", routeCheckpointPath]
        routeCheckpointLoadProcess.running = true
    }

    function routeBuildKey() {
        if (!buildData)
            return JSON.stringify(["", "", manualBandit === "auto" ? "None" : effectiveBandit])
        return JSON.stringify([
            buildData.name || "",
            buildData.class || "",
            manualBandit === "auto" ? (buildData.bandit || "None") : effectiveBandit
        ])
    }

    function tryStartRouteLog() {
        if (routeLogStarted || !routeCheckpointLoaded || !savedBuildReady || !routeSettingsLoaded
                || !routeData || !areasFile.loaded)
            return

        const checkpoint = loadedRouteCheckpoint
        const bandit = effectiveBandit
        if (routeData.mode !== routeMode || routeData.bandit !== bandit)
            return
        const checkpointCursor = checkpoint && checkpoint.version === 2
                && checkpoint.manualMode === true
                && routeData.sections[checkpoint.manualAct]
                && routeData.sections[checkpoint.manualAct].rows[checkpoint.manualStep]
            ? Object.assign({}, checkpoint, { act: checkpoint.manualAct, step: checkpoint.manualStep })
            : checkpoint
        const checkpointHasLogPosition = checkpoint && (checkpoint.version === 1 || checkpoint.version === 2)
            && typeof checkpoint.logStamp === "string"
        const checkpointMatchesCurrentRoute = RouteProgress.checkpointMatches(checkpointCursor, {
            buildKey: routeBuildKey(),
            routeFingerprint: routeData.fingerprint,
            routeMode: routeMode,
            bandit: bandit
        }, routeData.sections)
        if (checkpointHasLogPosition && checkpointMatchesCurrentRoute) {
            areaId = checkpoint.areaId
            previousAreaId = checkpoint.previousAreaId
            zone = checkpoint.zone || "Waiting for area..."
            checkpointLogStamp = checkpoint.logStamp
            routeCheckpointValid = true
            recoveryTargetAreaId = checkpoint.recoveryTargetAreaId || ""
            if (!routeCheckpointSelectionPending) {
                autoRouteAct = checkpointCursor.act
                autoRouteStep = checkpointCursor.step
            }
        } else {
            areaId = ""
            previousAreaId = ""
            zone = "Waiting for area..."
            checkpointLogStamp = ""
            routeCheckpointValid = false
            recoveryTargetAreaId = ""
            if (!routeCheckpointSelectionPending) {
                autoRouteAct = -1
                autoRouteStep = -1
            }
        }
        if (routeCheckpointSelectionPending) {
            const selectedRow = routeSections[autoRouteAct]
                && routeSections[autoRouteAct].rows[autoRouteStep]
            if (selectedRow)
                routeItems = selectedRow.items
        } else {
            updateRouteGoal()
        }
        const replayCheckpoint = !routeCheckpointSelectionPending
            && routeCheckpointValid && checkpointLogStamp
        const tailFromNow = routeCheckpointSelectionPending
            || routeCheckpointValid && !checkpointLogStamp
            || replayCheckpoint
        routeReplayPending = !!replayCheckpoint
        bufferedLiveRouteLines = []
        routeLogProcess.command = ["tail", "-n", tailFromNow ? "0" : "300", "-F", logPath]
        routeLogStarted = true
        routeLogProcess.running = true
        if (routeReplayPending) {
            routeReplayProcess.command = [pythonPath, routeStatePath, "--replay", logPath, checkpointLogStamp]
            routeReplayProcess.running = true
        }
    }

    function logStamp(line) {
        const match = line.match(/^(\d{4}\/\d{2}\/\d{2} \d{2}:\d{2}:\d{2}) (\d+)/)
        return match ? `${match[1]} ${match[2].padStart(12, "0")}` : ""
    }

    function saveRouteCheckpoint(stamp) {
        if (!routeData)
            return
        if (autoRouteAct < 0 || autoRouteStep < 0)
            return
        const bandit = effectiveBandit
        pendingRouteCheckpoint = JSON.stringify({
            version: 2,
            buildKey: routeBuildKey(),
            routeFingerprint: routeData.fingerprint,
            routeMode: routeMode,
            bandit: bandit,
            act: autoRouteAct,
            step: autoRouteStep,
            areaId: areaId,
            previousAreaId: previousAreaId,
            zone: zone,
            logStamp: stamp,
            recoveryTargetAreaId: recoveryTargetAreaId
        })
        checkpointLogStamp = stamp
        routeCheckpointValid = true
        if (routeCheckpointClearPending || routeCheckpointClearProcess.running) {
            routeCheckpointSavePending = true
            return
        }
        if (routeCheckpointSaveProcess.running) {
            routeCheckpointSavePending = true
            return
        }
        startRouteCheckpointSave()
    }

    function startRouteCheckpointSave() {
        routeCheckpointSaveProcess.command = [pythonPath, routeStatePath, "--write", routeCheckpointPath]
        routeCheckpointSaveProcess.running = true
    }

    function clearRouteCheckpoint() {
        routeCheckpointClearPending = true
        routeCheckpointResetRequested = true
        routeCheckpointSavePending = false
        loadedRouteCheckpoint = null
        routeCheckpointValid = false
        if (!routeCheckpointSaveProcess.running && !routeCheckpointClearProcess.running)
            startRouteCheckpointClear()
    }

    function startRouteCheckpointClear() {
        routeCheckpointClearPending = false
        routeCheckpointClearProcess.command = [pythonPath, routeStatePath, "--clear", routeCheckpointPath]
        routeCheckpointClearProcess.running = true
    }

    function handleRouteCheckpointLoad(data) {
        routeCheckpointResponseReceived = true
        if (routeCheckpointResetRequested) {
            loadedRouteCheckpoint = null
            routeCheckpointLoaded = true
            tryStartRouteLog()
            return
        }
        try {
            const result = JSON.parse(data)
            if (!result.ok)
                throw new Error(result.error || "Could not read route checkpoint")
            loadedRouteCheckpoint = result.checkpoint
        } catch (error) {
            loadedRouteCheckpoint = null
            console.warn("Could not read route checkpoint:", error)
        }
        routeCheckpointLoaded = true
        tryStartRouteLog()
    }

    function handleRouteCheckpointSave(data) {
        try {
            const result = JSON.parse(data)
            if (!result.ok)
                console.warn("Could not save route checkpoint:", result.error)
        } catch (error) {
            console.warn("Could not read route checkpoint writer response:", error)
        }
    }

    function handleRouteReplay(data) {
        try {
            const result = JSON.parse(data)
            if (!result.ok || !Array.isArray(result.events))
                throw new Error(result.error || "Invalid route replay response")
            if (!result.checkpointFound) {
                routeCheckpointValid = false
                console.warn("Route checkpoint log entry is missing; resuming from the next live area transition")
                return
            }
            for (const line of result.events)
                handleLine(line, true)
        } catch (error) {
            console.warn("Could not replay route log after checkpoint:", error)
        } finally {
            routeReplayPending = false
            const bufferedLines = bufferedLiveRouteLines
            bufferedLiveRouteLines = []
            for (const line of bufferedLines)
                handleLine(line)
        }
    }

    function importBuild() {
        const code = buildCodeInput.text.replace(/\s/g, "")
        if (!code) {
            importStatus = "Paste a PoB Export Code first"
            return
        }
        if (importProcess.running) {
            importStatus = "Import already running"
            return
        }
        pendingBuildCode = code
        importResponseReceived = false
        importStatus = "Reading skill sets..."
        importProcess.command = [pythonPath, parserPath, buildStatePath]
        importProcess.running = true
    }

    function showBuildWindow() {
        buildWindow.visible = true
        settingsTab = 0
        buildCodeInput.forceActiveFocus()
    }

    function toggleBuildWindow() {
        if (buildWindow.visible) {
            buildWindow.visible = false
            return
        }
        showBuildWindow()
    }

    function openBuildViewer() {
        if (!buildData)
            return
        buildWindow.visible = false
        buildViewerVisible = true
    }

    function toggleBuildViewer() {
        if (buildViewerVisible) {
            buildViewerVisible = false
            return
        }
        openBuildViewer()
    }

    function saveBuildState() {
        if (!buildData)
            return
        if (stateProcess.running) {
            buildStateSavePending = true
            return
        }
        pendingBuildState = JSON.stringify(buildData)
        stateProcess.command = [pythonPath, parserPath, "--save", buildStatePath]
        stateProcess.running = true
    }

    function setSkillSetEnabled(index, enabled) {
        if (!buildData || !buildData.skillSets[index])
            return
        buildData.skillSets[index].enabled = enabled
        buildData = buildData
        saveBuildState()
        updateRouteGoal()
    }

    function deleteBuild() {
        if (deleteBuildProcess.running)
            return
        deleteBuildProcess.command = [pythonPath, parserPath, "--delete", buildStatePath]
        deleteBuildProcess.running = true
    }

    function loadHudState() {
        if (!hudStatePath || !hudStateFile.loaded)
            return
        root.hudEnabled = true
        root.overlayVisible = true
        root.manualBandit = "auto"
        try {
            const state = JSON.parse(hudStateFile.text())
            if (state && typeof state.enabled === "boolean") {
                root.hudEnabled = state.enabled
                root.overlayVisible = state.enabled
            }
            if (state && root.banditOptions.some(option => option.value === state.bandit))
                root.manualBandit = state.bandit
            if (state && typeof state.logPath === "string" && state.logPath.trim())
                root.logPath = state.logPath
        } catch (error) {
        }
        root.routeSettingsLoaded = true
        if (root.routeData && root.routeData.bandit !== root.effectiveBandit)
            root.loadRouteData()
        root.tryStartRouteLog()
    }

    function saveHudState() {
        if (!hudStatePath)
            return
        if (hudStateProcess.running) {
            hudStateSavePending = true
            return
        }
        pendingHudState = JSON.stringify({
            enabled: root.hudEnabled,
            bandit: root.manualBandit,
            logPath: root.logPath
        })
        hudStateProcess.command = [pythonPath, parserPath, "--overlay-state", hudStatePath]
        hudStateProcess.running = true
    }

    function setLogPath(value) {
        const nextPath = value.trim()
        if (!nextPath || nextPath === logPath)
            return
        logPath = nextPath
        saveHudState()
        if (!routeLogStarted)
            return

        routeLogProcess.running = false
        routeReplayProcess.running = false
        routeReplayPending = false
        bufferedLiveRouteLines = []
        checkpointLogStamp = ""
        routeCheckpointValid = false
        routeLogProcess.command = ["tail", "-n", "0", "-F", logPath]
        routeLogProcess.running = true
    }

    function setHudEnabled(enabled) {
        root.hudEnabled = enabled
        root.overlayVisible = enabled
        root.saveHudState()
    }

    function setRouteBandit(value) {
        if (!banditOptions.some(option => option.value === value) || manualBandit === value)
            return
        manualBandit = value
        saveHudState()
        loadRouteData()
    }

    function saveHudGeometry() {
        if (hud.width <= 0 || hud.height <= 0)
            return
        const state = `${hud.screenLeft} ${hud.screenTop} ${Math.ceil(hud.width)} ${Math.ceil(hud.height)} ${root.overlayVisible ? 1 : 0} ${root.hudEnabled ? 1 : 0}`
        if (state === lastHudState)
            return
        lastHudState = state
        hudGeometryFile.setText(`${state}\n`)
    }

    function handleImportOutput(data) {
        try {
            const result = JSON.parse(data)
            if (!result.ok) {
                importStatus = result.error
                return
            }
            buildData = result.build
            importStatus = `Imported · ${buildData.skillSets.length} gem loadouts, ${buildData.treeSpecs.length} tree loadouts`
            loadRouteData()
        } catch (error) {
            importStatus = "Unexpected parser response"
            console.warn("PoB import response error:", error)
        }
    }

    function loadSavedBuild() {
        if (!savedBuildFile.loaded || !savedBuildFile.text())
            return
        try {
            buildData = JSON.parse(savedBuildFile.text())
            const needsReimport = buildData.parserVersion !== 4
                || buildData.skillSets.some(skillSet => skillSet.gems.some(gem => !gem.id))
            for (const skillSet of buildData.skillSets)
                skillSet.enabled = skillSet.enabled !== false
            importStatus = needsReimport ? "Re-import this PoB code to sync gem and passive tree loadouts" : ""
            loadRouteData()
        } catch (error) {
            importStatus = "Could not load saved build"
        }
    }

    IpcHandler {
        target: "poe-overlay"
        function openBuild() {
            root.toggleBuildWindow()
        }
        function openRoute() {
            buildWindow.visible = true
            root.settingsTab = 1
        }
        function routeCursorForward() {
            root.shiftRouteCursor(1)
        }
        function routeCursorBackward() {
            root.shiftRouteCursor(-1)
        }
        function openBuildViewer() {
            root.openBuildViewer()
        }
        function toggleBuildViewer() {
            root.toggleBuildViewer()
        }
        function closeBuild() {
            buildWindow.visible = false
        }
        function showHud() {
            root.overlayVisible = root.hudEnabled
        }
        function hideHud() {
            root.overlayVisible = false
            buildWindow.visible = false
            root.buildViewerVisible = false
        }
        function toggleHud() {
            root.setHudEnabled(!root.hudEnabled)
        }
        function toggleBuild() {
            root.toggleBuildWindow()
        }
    }

    Component.onCompleted: {
        loadRouteData()
        loadRouteCheckpoint()
    }

    Timer {
        interval: 2000
        running: !root.savedBuildReady
        repeat: false
        onTriggered: {
            root.savedBuildReady = true
            root.tryStartRouteLog()
        }
    }

    Timer {
        interval: 250
        running: true
        repeat: true
        onTriggered: root.saveHudGeometry()
    }

    Process {
        id: routeCheckpointLoadProcess
        stdout: StdioCollector {
            onStreamFinished: root.handleRouteCheckpointLoad(text)
        }
        stderr: StdioCollector {
            onStreamFinished: {
                if (text.trim().length)
                    console.warn("Route checkpoint reader:", text.trim())
            }
        }
        onExited: {
            Qt.callLater(() => {
                if (!root.routeCheckpointResponseReceived) {
                    root.loadedRouteCheckpoint = null
                    root.routeCheckpointLoaded = true
                    root.tryStartRouteLog()
                }
            })
        }
    }

    Process {
        id: routeCheckpointSaveProcess
        stdinEnabled: true
        stdout: StdioCollector {
            onStreamFinished: root.handleRouteCheckpointSave(text)
        }
        stderr: StdioCollector {
            onStreamFinished: {
                if (text.trim().length)
                    console.warn("Route checkpoint writer:", text.trim())
            }
        }
        onStarted: write(root.pendingRouteCheckpoint + "\n")
        onExited: {
            if (root.routeCheckpointClearPending) {
                root.startRouteCheckpointClear()
            } else if (root.routeCheckpointSavePending) {
                root.routeCheckpointSavePending = false
                root.startRouteCheckpointSave()
            }
        }
    }

    Process {
        id: routeCheckpointClearProcess
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const result = JSON.parse(text)
                    if (!result.ok)
                        console.warn("Could not clear route checkpoint:", result.error)
                } catch (error) {
                    console.warn("Could not read route checkpoint clear response:", error)
                }
            }
        }
        stderr: StdioCollector {
            onStreamFinished: {
                if (text.trim().length)
                    console.warn("Route checkpoint clearer:", text.trim())
            }
        }
        onExited: {
            if (root.routeCheckpointClearPending)
                root.startRouteCheckpointClear()
            else if (root.routeCheckpointSavePending) {
                root.routeCheckpointSavePending = false
                root.startRouteCheckpointSave()
            }
        }
    }

    Process {
        id: routeReplayProcess
        stdout: StdioCollector {
            onStreamFinished: root.handleRouteReplay(text)
        }
        stderr: StdioCollector {
            onStreamFinished: {
                if (text.trim().length)
                    console.warn("Route log replay:", text.trim())
            }
        }
    }

    Process {
        id: routeLoadProcess
        stdout: StdioCollector {
            onStreamFinished: root.handleRouteLoad(text)
        }
        stderr: StdioCollector {
            onStreamFinished: {
                if (text.trim().length)
                    console.warn("Route loader:", text.trim())
            }
        }
        onExited: {
            if (root.routeLoadPending) {
                root.routeLoadPending = false
                root.loadRouteData()
            }
        }
    }

    Process {
        id: importProcess
        stdinEnabled: true
        stdout: SplitParser {
            onRead: data => {
                root.importResponseReceived = true
                root.handleImportOutput(data)
            }
        }
        stderr: SplitParser {
            onRead: data => {
                if (data.trim().length)
                    root.importStatus = data.trim()
            }
        }
        onStarted: write(root.pendingBuildCode + "\n")
        onExited: (exitCode, exitStatus) => {
            if (!root.importResponseReceived && root.importStatus === "Reading skill sets...")
                root.importStatus = exitCode === 0 ? "Parser returned no data" : "Import process failed"
        }
    }

    Process {
        id: stateProcess
        stdinEnabled: true
        stdout: SplitParser {
            onRead: data => {
                try {
                    const result = JSON.parse(data)
                    if (!result.ok)
                        root.importStatus = result.error
                } catch (error) {
                    root.importStatus = "Could not save loadout selection"
                }
            }
        }
        onStarted: write(root.pendingBuildState + "\n")
        onExited: {
            if (root.buildStateSavePending) {
                root.buildStateSavePending = false
                root.saveBuildState()
            }
        }
    }

    Process {
        id: deleteBuildProcess
        onExited: (exitCode, exitStatus) => {
            if (exitCode === 0) {
                root.buildData = null
                root.routeItems = []
                root.importStatus = "Build removed"
                root.loadRouteData()
            } else {
                root.importStatus = "Could not remove build"
            }
        }
    }

    Process {
        id: hudStateProcess
        stdinEnabled: true
        stdout: SplitParser {
            onRead: data => {
                try {
                    const result = JSON.parse(data)
                    if (!result.ok)
                        root.importStatus = result.error
                } catch (error) {
                }
            }
        }
        onStarted: write(root.pendingHudState + "\n")
        onExited: {
            if (root.hudStateSavePending) {
                root.hudStateSavePending = false
                root.saveHudState()
            }
        }
    }

    Process {
        id: clipboardProcess
        command: ["wl-paste", "--no-newline"]
        stdout: StdioCollector {
            onStreamFinished: {
                buildCodeInput.text = text.trim()
                root.importStatus = buildCodeInput.text.length
                    ? "Pasted from clipboard"
                    : "Clipboard is empty"
            }
        }
    }

    FileView {
        id: savedBuildFile
        path: root.buildStatePath
        preload: true
        blockLoading: true
        printErrors: false
        onLoaded: {
            root.loadSavedBuild()
            root.savedBuildReady = true
            if (root.routeSettingsLoaded && root.routeData && root.routeData.bandit !== root.effectiveBandit)
                root.loadRouteData()
            root.tryStartRouteLog()
        }
        onLoadFailed: {
            root.buildData = null
            root.savedBuildReady = true
            root.tryStartRouteLog()
        }
    }

    FileView {
        id: hudStateFile
        path: root.hudStatePath
        preload: true
        blockLoading: true
        printErrors: false
        onLoaded: root.loadHudState()
        onLoadFailed: {
            root.routeSettingsLoaded = true
            root.tryStartRouteLog()
        }
    }

    FileView {
        id: hudGeometryFile
        path: root.hudGeometryPath
        printErrors: false
    }

    FileView {
        id: gemsFile
        path: root.gemsPath
        preload: true
        blockLoading: true
        onLoaded: root.updateRouteGoal()
    }

    FileView {
        id: questsFile
        path: root.questsPath
        preload: true
        blockLoading: true
        onLoaded: root.updateRouteGoal()
    }

    FileView {
        id: charactersFile
        path: root.charactersPath
        preload: true
        blockLoading: true
        onLoaded: root.updateRouteGoal()
    }

    FileView {
        id: vaalGemLookupFile
        path: root.vaalGemLookupPath
        preload: true
        blockLoading: true
        onLoaded: root.updateRouteGoal()
    }

    FileView {
        id: awakenedGemLookupFile
        path: root.awakenedGemLookupPath
        preload: true
        blockLoading: true
        onLoaded: root.updateRouteGoal()
    }

    FileView {
        id: areasFile
        path: root.areasPath
        preload: true
        blockLoading: true
        onLoaded: {
            root.updateRouteGoal()
            root.tryStartRouteLog()
        }
    }

    Process {
        id: routeLogProcess
        running: false
        stdout: SplitParser {
            onRead: data => root.handleLine(data)
        }
    }

    function normalizeQuestName(value) {
        return value.toLowerCase().replace(/_/g, " ").replace(/[^a-z0-9]/g, "")
    }

    function resolveQuestReferences(line, questsData) {
        const references = []
        const sourceQuestPattern = /\(quest-id:([^|)]+)(?:\|([^)]*))?\)/g
        let sourceQuest
        while ((sourceQuest = sourceQuestPattern.exec(line)) !== null) {
            const quest = questsData[sourceQuest[1]]
            if (!quest)
                continue
            const offerIds = sourceQuest[2]
                ? sourceQuest[2].split(",").filter(id => quest.reward_offers[id])
                : Object.keys(quest.reward_offers)
            if (offerIds.length)
                references.push({ quest: quest, offerIds: offerIds })
        }
        if (references.length)
            return references

        const pattern = /<([^>]+)>/g
        const npcPrefix = line.split("<")[0].match(/([a-z][a-z '\-]+):\s*$/i)
        const npcHint = npcPrefix ? npcPrefix[1].trim().toLowerCase() : ""
        let match

        while ((match = pattern.exec(line)) !== null) {
            const token = normalizeQuestName(match[1])
            const candidates = []
            for (const quest of Object.values(questsData)) {
                const questName = normalizeQuestName(quest.name)
                if (token === questName || /^\d+$/.test(token.substring(questName.length)) && token.startsWith(questName))
                    candidates.push(quest)
            }
            if (!candidates.length)
                continue

            const matchingNpc = candidates.filter(quest =>
                Object.values(quest.reward_offers).some(offer => offer && offer.quest_npc.toLowerCase() === npcHint)
            )
            const selected = matchingNpc.length ? matchingNpc : candidates
            for (const quest of selected) {
                const offerIds = Object.keys(quest.reward_offers).filter(id => {
                    const offer = quest.reward_offers[id]
                    return offer && (!npcHint || offer.quest_npc.toLowerCase() === npcHint)
                })
                if (offerIds.length && !references.some(reference => reference.quest.id === quest.id))
                    references.push({ quest, offerIds })
            }
        }
        return references
    }

    function normalizedGemId(gemId, vaalLookup, awakenedLookup) {
        const aliases = {
            "Metadata/Items/Gems/Smite": "Metadata/Items/Gems/SkillGemSmite",
            "Metadata/Items/Gems/ConsecratedPath": "Metadata/Items/Gems/SkillGemConsecratedPath",
            "Metadata/Items/Gems/VaalAncestralWarchief": "Metadata/Items/Gems/SkillGemVaalAncestralWarchief",
            "Metadata/Items/Gems/HeraldOfAgony": "Metadata/Items/Gems/SkillGemHeraldOfAgony",
            "Metadata/Items/Gems/HeraldOfPurity": "Metadata/Items/Gems/SkillGemHeraldOfPurity",
            "Metadata/Items/Gems/ScourgeArrow": "Metadata/Items/Gems/SkillGemScourgeArrow",
            "Metadata/Items/Gems/RainOfSpores": "Metadata/Items/Gems/SkillGemToxicRain",
            "Metadata/Items/Gems/SummonRelic": "Metadata/Items/Gems/SkillGemSummonRelic",
            "Metadata/Items/Gems/SkillGemNewPhaseRun": "Metadata/Items/Gems/SkillGemPhaseRun",
            "Metadata/Items/Gems/SkillGemNewArcticArmour": "Metadata/Items/Gems/SkillGemArcticArmour"
        }
        let normalized = aliases[gemId] || gemId
        normalized = vaalLookup[normalized] || normalized
        normalized = awakenedLookup[normalized] || normalized
        return normalized
    }

    function buildRequiredGems(gemData, vaalLookup, awakenedLookup) {
        const required = []
        const seen = ({})
        if (!buildData || !buildData.skillSets)
            return required

        for (const skillSet of buildData.skillSets) {
            if (skillSet.enabled === false)
                continue
            for (const gem of skillSet.gems) {
                let id = normalizedGemId(gem.id || "", vaalLookup, awakenedLookup)
                if (!gemData[id]) {
                    const targetName = gem.name.toLowerCase().replace(/^(vaal|awakened) /, "")
                    for (const candidateId of Object.keys(gemData)) {
                        const candidate = gemData[candidateId]
                        if (candidate && candidate.name && candidate.name.toLowerCase() === targetName) {
                            id = candidateId
                            break
                        }
                    }
                }
                if (!id || !gemData[id] || seen[id])
                    continue
                seen[id] = true
                required.push({ id: id, note: skillSet.note || skillSet.title || "Build" })
            }
        }
        return required
    }

    function gemAttributeColor(gem) {
        const colors = {
            strength: "#d95f5f",
            dexterity: "#62bd70",
            intelligence: "#638bd6"
        }
        return colors[gem.primary_attribute] || "#ffffff"
    }

    function gemCurrencyIcon(gem) {
        if (gem.required_level < 8)
            return "wisdom"
        if (gem.required_level < 16)
            return "transmutation"
        if (gem.required_level < 28)
            return "alteration"
        if (gem.required_level < 38)
            return "chance"
        return "alchemy"
    }

    function processQuestReference(reference, requiredGems, questGems, vendorGems, gemData) {
        const items = []
        if (!buildData || !buildData.class || !requiredGems.length)
            return items
        const characterClass = buildData.class.charAt(0).toUpperCase() + buildData.class.slice(1).toLowerCase()
        const offers = reference.offerIds.map(id => reference.quest.reward_offers[id]).filter(Boolean)

        for (const offer of offers) {
            for (const requiredGem of requiredGems) {
                if (questGems[requiredGem.id])
                    continue
                const reward = offer.quest[requiredGem.id]
                if (!reward || (reward.classes.length && !reward.classes.includes(characterClass)))
                    continue

                questGems[requiredGem.id] = true
                const gem = gemData[requiredGem.id]
                items.push({
                    html: `Take <font color="${gemAttributeColor(gem)}">${escapeHtml(gem.name)}</font> <font color="#99988e">· ${escapeHtml(requiredGem.note)}</font>`,
                    hint: false,
                    optional: false,
                    gem: true,
                    gemColor: gemAttributeColor(gem)
                })
                break
            }
        }

        for (const offer of offers) {
            for (const requiredGem of requiredGems) {
                if (vendorGems[requiredGem.id] || questGems[requiredGem.id])
                    continue
                const reward = offer.vendor[requiredGem.id]
                if (!reward || (reward.classes.length && !reward.classes.includes(characterClass)))
                    continue

                vendorGems[requiredGem.id] = true
                const gem = gemData[requiredGem.id]
                const currency = gemCurrencyIcon(gem)
                items.push({
                    html: `Buy <font color="${gemAttributeColor(gem)}">${escapeHtml(gem.name)}</font> <img src="${routeImageUrl("currency-" + currency + ".png")}" width="16" height="16"/> <font color="#99988e">— ${escapeHtml(reward.npc)} · ${escapeHtml(requiredGem.note)}</font>`,
                    hint: false,
                    optional: false,
                    gem: true,
                    gemColor: gemAttributeColor(gem)
                })
            }
        }
        return items
    }

    function escapeHtml(text) {
        return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    }

    function routeImageUrl(filename) {
        return Qt.resolvedUrl("routes/images/" + filename)
    }

    function readStaticJson(key, file) {
        if (!file.loaded)
            return ({})
        const text = file.text()
        const cached = staticJsonCache[key]
        if (cached && cached.text === text)
            return cached.value

        const value = JSON.parse(text)
        const nextCache = Object.assign({}, staticJsonCache)
        nextCache[key] = { text: text, value: value }
        staticJsonCache = nextCache
        return value
    }

    function formatGoalLine(line, areas) {
        line = line.split(";;")[0]
        line = line.replace(/\(quest-id:[^)]+\)/g, "")
        line = line.replace(/\s*&\s*(?=\(color:)/gi, " ")
        line = line.replace(/\(color:[^)]+\)/gi, "")
        line = line.replace(/\b(?:arena|npc|area|zone):/gi, "")

        const mode = line.match(/^(leaguestart|twinkrun):\s*/)
        if (mode && mode[1] !== routeMode)
            return ""
        if (mode)
            line = line.substring(mode[0].length)

        line = line.replace(/(^|\s)kill\s+(.+?)(?=\s+(?:for|in|at|on|to|and)\b|\s*\|\||\s*\(img:|\s*\(quest:|\s*\(lvl:|$)/gi,
            (whole, prefix, target) => {
                const normalizedTarget = target.trim().replace(/_/g, " ")
                if (!normalizedTarget || normalizedTarget.toLowerCase() === "everything")
                    return whole
                return `${prefix}kill (boss:${normalizedTarget})`
            })

        let html = ""
        let cursor = 0
        const markers = /(?:\b(?:Take|Use|Place|Set)\s+\(action-portal\)|\(action-logout\))|\(img:([^)]+)\)|\(hint\)_+|\(quest:([^)]*)\)|areaid([A-Za-z0-9_]+)|<([^>]+)>|\(boss:([^)]*)\)/g
        let match
        while ((match = markers.exec(line)) !== null) {
            html += escapeHtml(line.substring(cursor, match.index))
            if (match[0] === "(action-logout)") {
                html += '<font color="#b8a2c9">Log out to town</font>'
            } else if (match[0].includes("(action-portal)")) {
                const action = match[0].match(/^(Take|Use|Place|Set)/i)[0]
                html += `<font color="#b8a2c9">${action} <img src="${routeImageUrl("portal.png")}" width="16" height="16"/></font>`
            } else if (match[1]) {
                const image = match[1].replace(/ /g, "_")
                html += `<img src="${routeImageUrl(image + ".png")}" width="16" height="16"/>`
            } else if (match[0].startsWith("(hint)")) {
                html += `<font color="#80c7d4"><b>Hint</b></font> `
            } else if (match[2]) {
                html += `<font color="#7ee6a2">${escapeHtml(match[2].replace(/_/g, " "))}</font>`
            } else if (match[3]) {
                html += `<font color="#f0c674">${escapeHtml(areas[match[3]] || match[3])}</font>`
            } else if (match[4]) {
                html += `<font color="#7ee6a2">${escapeHtml(match[4].replace(/_/g, " "))}</font>`
            } else if (match[5]) {
                html += `<font color="#f28c38">${escapeHtml(match[5])}</font>`
            }
            cursor = markers.lastIndex
        }
        html += escapeHtml(line.substring(cursor))
        html = html.replace(/\(color:[^)]+\)/gi, "")
        return html.replace(/\s+/g, " ").trim()
    }

    function updateRouteGoal() {
        if (!areasFile.loaded || !routeData)
            return

        try {
            const areas = readStaticJson("areas", areasFile)
            const routeActs = routeData.sections
            const gemData = readStaticJson("gems", gemsFile)
            const questsData = readStaticJson("quests", questsFile)
            const characterData = readStaticJson("characters", charactersFile)
            const vaalLookup = readStaticJson("vaalLookup", vaalGemLookupFile)
            const awakenedLookup = readStaticJson("awakenedLookup", awakenedGemLookupFile)
            const areaNames = ({})
            let actIndex = -1
            for (const id of Object.keys(areas)) {
                const area = areas[id]
                areaNames[id] = area.name
                if (id === areaId)
                    actIndex = area.act - 1
            }

            const campaignStartTransition = RouteProgress.isCampaignStartTransition(
                routeActs,
                actIndex,
                areaId,
                previousAreaId
            )
            const recoveryStep = RouteProgress.resolveRecoveryStep(
                routeActs,
                areas,
                areaId,
                recoveryTargetAreaId,
                autoRouteAct,
                autoRouteStep
            )
            const progress = recoveryStep
                ? Object.assign({}, recoveryStep, { matched: true })
                : RouteProgress.resolveAutoStep(
                    routeActs,
                    actIndex,
                    areaId,
                    previousAreaId,
                    autoRouteAct,
                    autoRouteStep,
                    areas
                )
            const automaticAct = progress.act
            const automaticStep = progress.step
            const routeProgressMatched = progress.matched
            if (routeProgressMatched) {
                autoRouteAct = automaticAct
                autoRouteStep = automaticStep
            }
            routePausedForDetour = !routeProgressMatched
            const activeRouteRow = routeActs[autoRouteAct]
                && routeActs[autoRouteAct].rows[autoRouteStep]
            recoveryTargetAreaId = RouteProgress.updateRecoveryTarget(
                areas,
                previousAreaId,
                areaId,
                routeProgressMatched,
                recoveryTargetAreaId,
                activeRouteRow ? activeRouteRow.sourceAreaId : "",
                campaignStartTransition
            )

            const requiredGems = buildRequiredGems(gemData, vaalLookup, awakenedLookup)
            const questGems = ({})
            const vendorGems = ({})
            const className = buildData && buildData.class
                ? buildData.class.charAt(0).toUpperCase() + buildData.class.slice(1).toLowerCase()
                : ""
            const character = characterData[className]
            if (character) {
                questGems[character.start_gem_id] = true
                questGems[character.chest_gem_id] = true
            }

            const sections = []
            for (let act = 0; act < routeActs.length; act++) {
                const actSteps = routeActs[act].rows || []
                const rows = []
                for (let stepIndex = 0; stepIndex < actSteps.length; stepIndex++) {
                    const rowItems = []
                    const lines = actSteps[stepIndex].lines || []
                    for (const routeLine of lines) {
                        const rawLine = typeof routeLine === "string" ? routeLine : routeLine.text
                        const clauses = rawLine.split(/\s*\|\|\s*/)
                        for (const clause of clauses) {
                            const references = resolveQuestReferences(clause, questsData)
                            if (!references.length) {
                                let html = formatGoalLine(clause, areaNames)
                                if (html && routeLine.sub)
                                    html = `<font color="#80c7d4">↳</font> ${html}`
                                if (html)
                                    rowItems.push({
                                        html: html,
                                        hint: clause.includes("(hint)_"),
                                        optional: clause.toLowerCase().includes("optional:"),
                                        gem: false
                                    })
                                continue
                            }

                            const remainder = clause
                                .replace(/\(quest-id:[^)]+\)\(quest:[^)]+\)/g, "")
                                .replace(/^\s*(?:hand in|complete|finish)\s*/i, "")
                                .replace(/^[,\s]+|[,\s]+$/g, "")
                            const remainderHtml = formatGoalLine(remainder, areaNames)
                            if (remainderHtml)
                                rowItems.push({ html: remainderHtml, hint: false, optional: false, gem: false })

                            for (const reference of references) {
                                const npcNames = []
                                for (const offerId of reference.offerIds) {
                                    const npc = reference.quest.reward_offers[offerId].quest_npc
                                    if (!npcNames.includes(npc))
                                        npcNames.push(npc)
                                }
                                rowItems.push({
                                    html: `Hand in <img src="${routeImageUrl("quest-reward.png")}" width="16" height="16"/> <font color="#f0c674">${escapeHtml(reference.quest.name)}</font> <font color="#99988e">— ${escapeHtml(npcNames.join(", "))}</font>`,
                                    hint: false,
                                    optional: false,
                                    gem: false,
                                    quest: true
                                })
                                const gemItems = processQuestReference(
                                    reference,
                                    requiredGems,
                                    questGems,
                                    vendorGems,
                                    gemData
                                )
                                rowItems.push(...gemItems)
                            }
                        }
                    }
                    rows.push({
                        act: act,
                        step: stepIndex,
                        sourceAreaId: actSteps[stepIndex].sourceAreaId,
                        destinationAreaId: actSteps[stepIndex].destinationAreaId,
                        items: rowItems,
                        html: rowItems.map(item => item.html).join("<br/>")
                    })
                }
                sections.push({ index: act, title: routeActs[act].title, rows: rows })
            }

            const collapsed = ({})
            for (const section of sections) {
                const key = String(section.index)
                collapsed[key] = Object.prototype.hasOwnProperty.call(collapsedActs, key)
                    ? collapsedActs[key]
                    : section.index !== (routeProgressMatched ? actIndex : autoRouteAct)
            }
            collapsedActs = collapsed
            routeSections = sections

            const localStep = !routeProgressMatched
                ? RouteProgress.findLocalStep(sections, actIndex, areaId, autoRouteAct, autoRouteStep)
                : null
            if (routeProgressMatched && sections[automaticAct] && sections[automaticAct].rows[automaticStep])
                routeItems = sections[automaticAct].rows[automaticStep].items
            else if (localStep && sections[localStep.act].rows[localStep.step])
                routeItems = sections[localStep.act].rows[localStep.step].items
            else {
                const pausedStep = RouteProgress.findPausedStep(
                    sections,
                    actIndex,
                    areaId,
                    autoRouteAct,
                    autoRouteStep
                )
                if (pausedStep && sections[pausedStep.act].rows[pausedStep.step])
                    routeItems = sections[pausedStep.act].rows[pausedStep.step].items
            }
            if (recoveryTargetAreaId) {
                const recoveryStep = RouteProgress.findRecoveryStep(
                    routeSections,
                    areas,
                    recoveryTargetAreaId,
                    autoRouteAct,
                    autoRouteStep
                )
                const recoveryRow = recoveryStep
                    && routeSections[recoveryStep.act].rows[recoveryStep.step]
                if (!localStep && recoveryRow)
                    routeItems = recoveryRow.items
                const recoveryArea = areas[recoveryTargetAreaId]
                const recoveryName = recoveryArea ? recoveryArea.name : recoveryTargetAreaId
                routeItems = [{
                    html: `<font color="#b8a2c9">Return to ${escapeHtml(recoveryName)}</font>`,
                    hint: false,
                    optional: false,
                    gem: false,
                    recovery: true
                }, ...routeItems]
            }
        } catch (error) {
            routeItems = [{ html: "Could not read route data", hint: false, optional: false }]
            console.warn("Could not load campaign route data:", error)
        }
    }

    function selectRouteStep(act, step) {
        const selectedSection = routeSections[act]
        const selectedRow = selectedSection && selectedSection.rows[step]
        if (!selectedRow)
            return
        autoRouteAct = act
        autoRouteStep = step
        recoveryTargetAreaId = ""
        routePausedForDetour = false
        routeItems = selectedRow.items
        routeCheckpointSelectionPending = !checkpointLogStamp
        saveRouteCheckpoint(checkpointLogStamp)
    }

    function shiftRouteCursor(delta) {
        if (!routeSections.length || delta === 0)
            return
        const next = RouteProgress.shiftRouteCursor(routeSections, autoRouteAct, autoRouteStep, delta)
        if (next)
            selectRouteStep(next.act, next.step)
    }

    function resetRouteStep() {
        autoRouteAct = -1
        autoRouteStep = -1
        recoveryTargetAreaId = ""
        routeCheckpointSavePending = false
        routeCheckpointSelectionPending = false
        routeItems = []
        clearRouteCheckpoint()
    }

    function toggleRouteAct(act) {
        const next = Object.assign({}, collapsedActs)
        const key = String(act)
        next[key] = !next[key]
        collapsedActs = next
    }

    // Parse one line from Client.txt.
    function handleLine(line, replaying = false) {
        if (routeReplayPending && !replaying) {
            bufferedLiveRouteLines = bufferedLiveRouteLines.concat([line])
            return
        }
        if (line.includes("***** LOG FILE OPENING *****")) {
            routeCheckpointValid = false
            pendingGeneratedAreaId = ""
            return
        }
        const stamp = logStamp(line)
        if (routeCheckpointValid && stamp && checkpointLogStamp && stamp <= checkpointLogStamp)
            return

        const generated = line.match(/Generating level\s+\d+\s+area\s+"([^"]+)"/)
        if (generated)
            pendingGeneratedAreaId = generated[1]

        const marker = "You have entered "
        const i = line.indexOf(marker)
        if (i < 0)
            return
        // Keep only the area name after the log marker.
        zone = line.substring(i + marker.length).replace(/\.\s*$/, "")
        if (!pendingGeneratedAreaId)
            return

        previousAreaId = areaId
        areaId = pendingGeneratedAreaId
        pendingGeneratedAreaId = ""
        if (routeCheckpointSelectionPending) {
            routeCheckpointSelectionPending = false
            const selectedRow = routeSections[autoRouteAct]
                && routeSections[autoRouteAct].rows[autoRouteStep]
            if (selectedRow)
                routeItems = selectedRow.items
        } else {
            updateRouteGoal()
        }
        saveRouteCheckpoint(stamp)
    }

    Hud {
        id: hud
        visible: root.overlayVisible
        zone: root.zone
        routePausedForDetour: root.routePausedForDetour
        routeItems: root.routeItems
    }

    BuildViewer {
        id: buildViewer
        buildData: root.buildData
        viewerVisible: root.buildViewerVisible
        onCloseRequested: root.buildViewerVisible = false
    }

    PanelWindow {
        id: buildWindow
        visible: false
        implicitWidth: 620
        implicitHeight: buildContent.implicitHeight + 44
        anchors {
            top: true
            left: true
        }
        margins {
            top: Math.max(16, Math.min(270, Screen.height - buildWindow.implicitHeight - 16))
            left: 650
        }
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: visible ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"

        Rectangle {
            anchors.fill: parent
            color: "#171916"

            Column {
                id: buildContent
                x: 22
                y: 22
                width: parent.width - 44
                spacing: 14

                Shortcut {
                    sequence: "Escape"
                    enabled: buildWindow.visible
                    onActivated: buildWindow.visible = false
                }

                TabBar {
                    id: settingsTabs
                    width: parent.width
                    currentIndex: root.settingsTab
                    onCurrentIndexChanged: root.settingsTab = currentIndex

                    TabButton {
                        text: "Import"
                        contentItem: Text {
                            text: parent.text
                            color: parent.checked ? "#f2eee6" : "#aaa99e"
                            font.pixelSize: 13
                            font.weight: parent.checked ? Font.DemiBold : Font.Normal
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                        background: Rectangle {
                            color: parent.checked ? "#34382f" : parent.hovered ? "#252822" : "#1c1f1b"
                            border.color: parent.checked ? "#d8a85e" : "#41463d"
                            radius: 4
                        }
                    }
                    TabButton {
                        text: "Route"
                        contentItem: Text {
                            text: parent.text
                            color: parent.checked ? "#f2eee6" : "#aaa99e"
                            font.pixelSize: 13
                            font.weight: parent.checked ? Font.DemiBold : Font.Normal
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                        background: Rectangle {
                            color: parent.checked ? "#34382f" : parent.hovered ? "#252822" : "#1c1f1b"
                            border.color: parent.checked ? "#d8a85e" : "#41463d"
                            radius: 4
                        }
                    }
                }

                StackLayout {
                    id: settingsPages
                    width: parent.width
                    currentIndex: settingsTabs.currentIndex
                    implicitHeight: currentIndex === 0 ? importPage.implicitHeight : routePage.implicitHeight

                    Column {
                        id: importPage
                        width: settingsPages.width
                        spacing: 12

                        Text {
                            text: "Paste a PoB Export Code"
                            color: "#f2eee6"
                            font.pixelSize: 18
                            font.weight: Font.DemiBold
                        }

                        Text {
                            text: "Path to Client.txt"
                            color: "#d8d5ca"
                            font.pixelSize: 12
                        }

                        TextField {
                            id: gameLogPathInput
                            width: parent.width
                            text: root.logPath
                            placeholderText: "Path to Path of Exile's Client.txt"
                            selectByMouse: true
                            color: "#ece9df"
                            placeholderTextColor: "#7d8277"
                            onEditingFinished: root.setLogPath(text)
                            background: Rectangle {
                                color: "#222620"
                                border.color: gameLogPathInput.activeFocus ? "#d8a85e" : "#4a5047"
                                radius: 4
                            }
                        }

                        Text {
                            text: "Used to track campaign progress. The path is saved on this device."
                            color: "#a8aa9f"
                            font.pixelSize: 11
                            wrapMode: Text.Wrap
                            width: parent.width
                        }

                        TextArea {
                            id: buildCodeInput
                            width: parent.width
                            height: 96
                            placeholderText: "PoB Export Code"
                            wrapMode: TextEdit.WrapAnywhere
                            selectByMouse: true
                            color: "#ece9df"
                            placeholderTextColor: "#7d8277"
                            background: Rectangle {
                                color: "#222620"
                                border.color: buildCodeInput.activeFocus ? "#d8a85e" : "#4a5047"
                                radius: 4
                            }
                        }

                        Row {
                            width: parent.width
                            spacing: 8

                            Button {
                                text: importProcess.running ? "Importing..." : "Import"
                                enabled: !importProcess.running
                                onClicked: root.importBuild()
                                contentItem: Text {
                                    text: parent.text
                                    color: "#f2eee6"
                                    font.pixelSize: 13
                                    horizontalAlignment: Text.AlignHCenter
                                    verticalAlignment: Text.AlignVCenter
                                }
                                background: Rectangle {
                                    implicitWidth: 105
                                    implicitHeight: 34
                                    radius: 4
                                    color: parent.down ? "#9c7139" : parent.hovered ? "#383c34" : "#2b2f29"
                                    border.color: parent.down ? "#e4ad55" : "#585e52"
                                }
                            }

                            Button {
                                text: "Paste"
                                onClicked: clipboardProcess.running = true
                                contentItem: Text {
                                    text: parent.text
                                    color: "#d8d5ca"
                                    font.pixelSize: 13
                                    horizontalAlignment: Text.AlignHCenter
                                    verticalAlignment: Text.AlignVCenter
                                }
                                background: Rectangle {
                                    implicitWidth: 105
                                    implicitHeight: 34
                                    radius: 4
                                    color: parent.down ? "#33372f" : parent.hovered ? "#2b2f29" : "#20231f"
                                    border.color: "#4a5047"
                                }
                            }

                            Button {
                                visible: !!root.buildData
                                text: "View build"
                                onClicked: root.openBuildViewer()
                                contentItem: Text {
                                    text: parent.text
                                    color: "#d8d5ca"
                                    font.pixelSize: 12
                                    horizontalAlignment: Text.AlignHCenter
                                    verticalAlignment: Text.AlignVCenter
                                }
                                background: Rectangle {
                                    implicitWidth: 96
                                    implicitHeight: 34
                                    radius: 4
                                    color: parent.down ? "#33372f" : parent.hovered ? "#2b2f29" : "#20231f"
                                    border.color: "#4a5047"
                                }
                            }

                            Button {
                                visible: !!root.buildData
                                text: "Remove build"
                                onClicked: root.deleteBuild()
                                contentItem: Text {
                                    text: parent.text
                                    color: "#e9a29a"
                                    font.pixelSize: 12
                                    horizontalAlignment: Text.AlignHCenter
                                    verticalAlignment: Text.AlignVCenter
                                }
                                background: Rectangle {
                                    implicitWidth: 112
                                    implicitHeight: 34
                                    radius: 4
                                    color: parent.down ? "#482a27" : parent.hovered ? "#352522" : "#20201e"
                                    border.color: "#70413b"
                                }
                            }

                            Button {
                                text: "Close"
                                onClicked: buildWindow.visible = false
                                contentItem: Text {
                                    text: parent.text
                                    color: "#d8d5ca"
                                    font.pixelSize: 12
                                    horizontalAlignment: Text.AlignHCenter
                                    verticalAlignment: Text.AlignVCenter
                                }
                                background: Rectangle {
                                    implicitWidth: 92
                                    implicitHeight: 34
                                    radius: 4
                                    color: parent.down ? "#33372f" : parent.hovered ? "#2b2f29" : "#20231f"
                                    border.color: "#4a5047"
                                }
                            }
                        }

                        Text {
                            visible: root.importStatus.length > 0
                            width: parent.width
                            text: root.importStatus
                            color: root.importStatus.startsWith("Imported") || root.importStatus.startsWith("Saved") ? "#a9cf91" : "#d7bd85"
                            font.pixelSize: 12
                            wrapMode: Text.Wrap
                        }

                        Row {
                            visible: !!root.buildData
                            width: parent.width
                            spacing: 8

                            Text {
                                width: parent.width
                                text: root.buildData
                                    ? `${root.buildData.class} ${root.buildData.ascendancy} · Lv. ${root.buildData.level}`
                                    : ""
                                color: "#e4ad55"
                                font.pixelSize: 13
                                elide: Text.ElideRight
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }

                        Text {
                            visible: !!root.buildData
                            text: "Loadouts in route"
                            color: "#f2eee6"
                            font.pixelSize: 14
                            font.weight: Font.Medium
                        }

                        Flickable {
                            id: loadoutList
                            visible: !!root.buildData
                            width: parent.width
                            height: root.buildData
                                ? Math.min(Screen.height * 0.45, Math.max(38, root.buildData.skillSets.length * 36))
                                : 0
                            contentWidth: width
                            contentHeight: loadoutColumn.implicitHeight
                            clip: true

                            Column {
                                id: loadoutColumn
                                width: loadoutList.width
                                spacing: 2

                                Repeater {
                                    model: root.buildData ? root.buildData.skillSets : []

                                    delegate: CheckBox {
                                        id: loadoutCheck
                                        required property var modelData
                                        required property int index
                                        width: parent.width
                                        height: 34
                                        checked: modelData.enabled !== false
                                        text: `${modelData.title} · ${modelData.gems.length} gems`
                                        onToggled: root.setSkillSetEnabled(index, checked)

                                        indicator: Rectangle {
                                            x: parent.leftPadding
                                            y: (parent.height - height) / 2
                                            width: 18
                                            height: 18
                                            radius: 3
                                            color: parent.checked ? "#d8a85e" : "#222620"
                                            border.color: parent.checked ? "#e4ad55" : "#64685c"

                                            Text {
                                                anchors.centerIn: parent
                                                text: "✓"
                                                color: "#171916"
                                                font.pixelSize: 13
                                                font.weight: Font.Bold
                                                visible: loadoutCheck.checked
                                            }
                                        }

                                        contentItem: Text {
                                            leftPadding: parent.indicator.width + parent.spacing
                                            text: parent.text
                                            color: parent.checked ? "#ece9df" : "#a5a69c"
                                            font.pixelSize: 13
                                            verticalAlignment: Text.AlignVCenter
                                            elide: Text.ElideRight
                                        }
                                    }
                                }
                            }
                        }
                    }

                    Column {
                        id: routePage
                        width: settingsPages.width
                        spacing: 10

                        Row {
                            id: routeStatusRow
                            width: parent.width
                            spacing: 8

                            Text {
                                width: parent.width
                                text: root.autoRouteAct >= 0 && root.routeSections[root.autoRouteAct]
                                    ? `Checkpoint · ${root.routeSections[root.autoRouteAct].title}`
                                    : `No checkpoint · ${root.zone}`
                                color: "#e4ad55"
                                font.pixelSize: 16
                                font.weight: Font.DemiBold
                                elide: Text.ElideRight
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }

                        Row {
                            width: parent.width
                            spacing: 10
                            height: 34

                            Text {
                                text: "Act 2 reward"
                                color: "#d2d0c7"
                                font.pixelSize: 13
                                anchors.verticalCenter: parent.verticalCenter
                            }

                            ComboBox {
                                id: banditSelector
                                model: root.banditOptions
                                textRole: "label"
                                valueRole: "value"
                                currentValue: root.manualBandit
                                onActivated: root.setRouteBandit(currentValue)
                                implicitWidth: 190
                                height: 34
                                delegate: ItemDelegate {
                                    required property var modelData
                                    width: banditSelector.popup.width
                                    height: optionContent.implicitHeight + 12
                                    background: Rectangle {
                                        color: parent.highlighted ? "#34382f" : "#171916"
                                    }
                                    contentItem: Column {
                                        id: optionContent
                                        spacing: 3

                                        Text {
                                            text: modelData.label
                                            color: "#eee9df"
                                            font.pixelSize: 13
                                        }

                                        Text {
                                            width: parent.width
                                            text: modelData.description
                                            color: "#aaa99e"
                                            font.pixelSize: 11
                                            wrapMode: Text.Wrap
                                        }
                                    }
                                }
                                popup.width: 360
                                popup.background: Rectangle {
                                    color: "#171916"
                                    border.color: "#4a5047"
                                    radius: 4
                                }
                                popup.contentItem: ListView {
                                    clip: true
                                    implicitHeight: Math.min(contentHeight, 280)
                                    model: banditSelector.popup.visible ? banditSelector.delegateModel : null
                                    currentIndex: banditSelector.highlightedIndex
                                    ScrollIndicator.vertical: ScrollIndicator {}
                                }
                                contentItem: Text {
                                    leftPadding: 10
                                    rightPadding: 28
                                    text: banditSelector.displayText
                                    color: "#eee9df"
                                    font.pixelSize: 13
                                    verticalAlignment: Text.AlignVCenter
                                    elide: Text.ElideRight
                                }
                                background: Rectangle {
                                    color: "#222620"
                                    border.color: banditSelector.activeFocus ? "#d8a85e" : "#4a5047"
                                    radius: 4
                                }
                            }
                        }

                        Text {
                            width: parent.width
                            text: `${root.manualBandit === "auto" ? (root.buildData ? "PoB choice" : "Default choice") : "Route choice"}: ${root.effectiveBanditDescription}`
                            color: "#aaa99e"
                            font.pixelSize: 12
                            wrapMode: Text.Wrap
                        }

                        Row {
                            id: routeActionsRow
                            width: parent.width
                            spacing: 8

                            Button {
                                visible: root.routeSections.length > 0
                                text: "Reset"
                                onClicked: root.resetRouteStep()
                                contentItem: Text {
                                    text: parent.text
                                    color: "#eee9df"
                                    font.pixelSize: 12
                                    horizontalAlignment: Text.AlignHCenter
                                    verticalAlignment: Text.AlignVCenter
                                }
                                background: Rectangle {
                                    implicitWidth: 62
                                    implicitHeight: 30
                                    color: parent.hovered ? "#3a3129" : "#2c241f"
                                    border.color: "#8a5d36"
                                    radius: 4
                                }
                            }

                            Button {
                                text: root.hudEnabled ? "Hide HUD" : "Show HUD"
                                onClicked: root.setHudEnabled(!root.hudEnabled)
                                contentItem: Text {
                                    text: parent.text
                                    color: "#eee9df"
                                    font.pixelSize: 12
                                    horizontalAlignment: Text.AlignHCenter
                                    verticalAlignment: Text.AlignVCenter
                                }
                                background: Rectangle {
                                    implicitWidth: 82
                                    implicitHeight: 30
                                    color: parent.hovered ? "#3b382d" : "#26241f"
                                    border.color: root.hudEnabled ? "#a2b786" : "#756342"
                                    radius: 4
                                }
                            }
                        }

                        Flickable {
                            id: fullRouteView
                            width: parent.width
                            height: Math.min(routeSectionsColumn.implicitHeight, Math.max(160, Screen.height * 0.48))
                            contentWidth: width
                            contentHeight: routeSectionsColumn.implicitHeight
                            clip: true

                            Column {
                                id: routeSectionsColumn
                                width: fullRouteView.width
                                spacing: 8

                                Repeater {
                                    model: root.routeSections

                                    delegate: Column {
                                        required property var modelData
                                        width: routeSectionsColumn.width
                                        spacing: 3

                                        Button {
                                            width: parent.width
                                            height: 34
                                            text: `${root.collapsedActs[String(modelData.index)] ? ">" : "v"}  ${modelData.title}`
                                            onClicked: root.toggleRouteAct(modelData.index)
                                            contentItem: Text {
                                                text: parent.text
                                                color: "#e4ad55"
                                                font.pixelSize: 14
                                                font.weight: Font.DemiBold
                                                horizontalAlignment: Text.AlignLeft
                                                verticalAlignment: Text.AlignVCenter
                                                leftPadding: 10
                                            }
                                            background: Rectangle {
                                                color: parent.hovered ? "#30332c" : "#22251f"
                                                border.color: "#4d4a3e"
                                                radius: 4
                                            }
                                        }

                                        Column {
                                            visible: !root.collapsedActs[String(modelData.index)]
                                            width: parent.width
                                            spacing: 2

                                            Repeater {
                                                model: modelData.rows

                                                delegate: Button {
                                                    id: routeRowButton
                                                    required property var modelData
                                                    width: parent.width
                                                    height: Math.max(34, routeRowText.implicitHeight + 12)
                                                    onClicked: root.selectRouteStep(modelData.act, modelData.step)

                                                    contentItem: Row {
                                                        spacing: 8

                                                        Rectangle {
                                                            width: 6
                                                            height: 6
                                                            radius: 3
                                                            anchors.verticalCenter: parent.verticalCenter
                                                            color: modelData.act === root.autoRouteAct && modelData.step === root.autoRouteStep
                                                                ? "#e4ad55" : "#77796f"
                                                        }

                                                        Text {
                                                            id: routeRowText
                                                            width: parent.width - 22
                                                            text: modelData.html || "(no steps)"
                                                            textFormat: Text.RichText
                                                                color: modelData.act === root.autoRouteAct && modelData.step === root.autoRouteStep
                                                                ? "#f2eee6" : "#c2c0b7"
                                                            font.pixelSize: 13
                                                            wrapMode: Text.Wrap
                                                        }
                                                    }

                                                    background: Rectangle {
                                                            color: modelData.act === root.autoRouteAct && modelData.step === root.autoRouteStep
                                                            ? "#39372d" : parent.hovered ? "#292c26" : "transparent"
                                                            border.color: modelData.act === root.autoRouteAct && modelData.step === root.autoRouteStep
                                                            ? "#756342" : "transparent"
                                                        radius: 3
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
        }
    }
}
