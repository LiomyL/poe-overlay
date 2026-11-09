import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Window
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "tree_view.js" as TreeView

PanelWindow {
    id: root

    signal closeRequested()

    property bool viewerVisible: false
    property bool keyboardFocusRequested: true
    property var buildData: null
    property int viewMode: 2
    property int selectedTreeIndex: 0
    property int selectedGemIndex: 0
    property int viewerWidth: 430
    property int viewerHeight: 900
    readonly property int viewerTopMargin: 24
    readonly property int viewerRightMargin: 24
    property bool viewerStateLoaded: false
    property bool restoringViewerState: false
    property bool hasStoredViewerState: false
    property string storedCameraTreeKey: ""
    property real resizeStartGlobalX: 0
    property real resizeStartGlobalY: 0
    property var passiveTreeData: null
    property var treeNodes: ({})
    property var nodeGraphIndices: ({})
    property var treeConnections: []
    property var gemData: ({})
    property var hoveredNode: null
    property string treeDataError: ""
    property string cachedTreeVersion: ""
    property string cachedTreePath: ""
    property string pendingTreeVersion: ""
    property string treeDownloadError: ""
    property var attemptedTreeDownloads: []
    property real treeScale: 0.01
    property real treeCenterX: 0
    property real treeCenterY: 0
    readonly property string treeCacheDir: (Quickshell.env("XDG_CACHE_HOME")
        || Quickshell.env("HOME") + "/.cache") + "/poe-overlay/passive-tree"
    readonly property string treePythonPath: Quickshell.env("POE_OVERLAY_PYTHON") || "python3"

    readonly property var treeSpecs: buildData && Array.isArray(buildData.treeSpecs) ? buildData.treeSpecs : []
    readonly property var skillSets: buildData && Array.isArray(buildData.skillSets) ? buildData.skillSets : []
    readonly property var selectedTree: treeSpecs[selectedTreeIndex] || null
    readonly property var previousTree: selectedTreeIndex > 0 ? treeSpecs[selectedTreeIndex - 1] : null
    readonly property var selectedSkillSet: skillSets[selectedGemIndex] || null
    readonly property var treeDelta: TreeView.compareTrees(selectedTree, previousTree)
    readonly property var activeNodeIds: new Set(treeDelta.active)
    readonly property var addedNodeIds: new Set(treeDelta.added)
    readonly property var removedNodeIds: new Set(treeDelta.removed)
    readonly property bool treeVisible: viewMode !== 1
    readonly property bool gemsVisible: viewMode !== 0
    readonly property string currentTreeKey: selectedTree ? `${selectedTree.version}|${selectedTree.title}` : ""
    readonly property int minimumViewerHeight: {
        const gemHeight = gemGroups ? gemGroups.implicitHeight : 0
        const requiredHeight = viewMode === 1
            ? gemHeight + 81
            : viewMode === 2
                ? gemHeight + 300
                : 420
        return Math.min(Screen.height - 48, Math.max(220, requiredHeight))
    }

    visible: viewerVisible
    focusable: viewerVisible
    implicitWidth: viewerWidth
    implicitHeight: viewerHeight

    anchors {
        top: true
        right: true
    }
    margins {
        top: viewerTopMargin
        right: viewerRightMargin
    }

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: viewerVisible && keyboardFocusRequested
        ? WlrKeyboardFocus.Exclusive
        : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"

    onViewerVisibleChanged: {
        if (viewerVisible) {
            keyboardFocusRequested = true
            focusRefreshTimer.restart()
        } else {
            focusRefreshTimer.stop()
            keyboardFocusRequested = false
        }
    }

    Component.onCompleted: {
        if (viewerVisible)
            focusRefreshTimer.start()
    }

    onBuildDataChanged: resetViewer()
    onSelectedTreeIndexChanged: {
        Qt.callLater(focusTreeChanges)
        scheduleViewerStateSave()
    }
    onSelectedGemIndexChanged: scheduleViewerStateSave()
    onViewModeChanged: {
        scheduleViewerStateSave()
        Qt.callLater(clampViewerHeight)
        if (treeVisible)
            treeCanvasRefreshTimer.restart()
    }
    onViewerWidthChanged: scheduleViewerStateSave()
    onViewerHeightChanged: scheduleViewerStateSave()
    onTreeScaleChanged: scheduleViewerStateSave()
    onTreeCenterXChanged: scheduleViewerStateSave()
    onTreeCenterYChanged: scheduleViewerStateSave()

    function restoreViewerState() {
        restoringViewerState = true
        viewerStateLoaded = true
        try {
            const state = JSON.parse(viewerStateFile.text())
            if (state && typeof state === "object") {
                hasStoredViewerState = true
                viewMode = Math.max(0, Math.min(2, Number(state.viewMode) || 0))
                selectedTreeIndex = Math.max(0, Number(state.selectedTreeIndex) || 0)
                selectedGemIndex = Math.max(0, Number(state.selectedGemIndex) || 0)
                viewerWidth = Math.max(320, Math.min(Screen.width - 48, Number(state.width) || 430))
                viewerHeight = Math.max(minimumViewerHeight, Math.min(Screen.height - 48, Number(state.height) || 900))
                treeScale = Math.max(0.00015, Math.min(4, Number(state.treeScale) || 0.01))
                treeCenterX = Number(state.treeCenterX) || 0
                treeCenterY = Number(state.treeCenterY) || 0
                storedCameraTreeKey = state.cameraTreeKey || ""
            }
        } catch (error) {
            hasStoredViewerState = false
        }
        restoringViewerState = false
        resetViewer()
    }

    function scheduleViewerStateSave() {
        if (!viewerStateLoaded || restoringViewerState)
            return
        viewerStateSaveTimer.restart()
    }

    function refreshTreeCanvas() {
        if (treeCanvas.available && treeCanvas.visible && treeCanvas.width > 0 && treeCanvas.height > 0)
            treeCanvas.requestPaint()
    }

    function resizePointerGlobalPosition() {
        const point = resizeHandler.centroid.position
        return {
            x: Screen.width - viewerRightMargin - width + point.x,
            y: viewerTopMargin + height - resizeGrip.height + point.y,
        }
    }

    function clampViewerHeight() {
        viewerHeight = Math.max(minimumViewerHeight, Math.min(Screen.height - 48, viewerHeight))
    }

    function saveViewerState() {
        if (!viewerStateLoaded || restoringViewerState)
            return
        const state = {
            viewMode: viewMode,
            selectedTreeIndex: selectedTreeIndex,
            selectedGemIndex: selectedGemIndex,
            width: viewerWidth,
            height: viewerHeight,
            treeScale: treeScale,
            treeCenterX: treeCenterX,
            treeCenterY: treeCenterY,
            cameraTreeKey: currentTreeKey,
        }
        viewerStateFile.setText(JSON.stringify(state) + "\n")
        storedCameraTreeKey = currentTreeKey
    }

    function resetViewer() {
        if (!hasStoredViewerState) {
            const activeTree = buildData ? Number(buildData.activeTreeSpec || 1) - 1 : 0
            selectedTreeIndex = Math.max(0, Math.min(activeTree, treeSpecs.length - 1))
            const activeGem = buildData ? String(buildData.activeSkillSet || "1") : "1"
            const matchingGem = skillSets.findIndex(skillSet => String(skillSet.id) === activeGem)
            selectedGemIndex = matchingGem >= 0 ? matchingGem : 0
        } else {
            selectedTreeIndex = Math.max(0, Math.min(selectedTreeIndex, treeSpecs.length - 1))
            selectedGemIndex = Math.max(0, Math.min(selectedGemIndex, skillSets.length - 1))
        }
        passiveTreeData = null
        treeNodes = ({})
        treeConnections = []
        treeDataError = ""
        Qt.callLater(loadTreeData)
    }

    function loadTreeData() {
        if (!selectedTree || !selectedTree.version || !treeDataFile.loaded)
            return
        try {
            const data = JSON.parse(treeDataFile.text())
            const nodes = ({})
            const nodeGraphs = ({})
            const connections = []
            for (let graphIndex = 0; graphIndex < (data.graphs || []).length; graphIndex++) {
                const graph = data.graphs[graphIndex]
                for (const id of Object.keys(graph.nodes || {}))
                    nodes[id] = graph.nodes[id]
                for (const id of Object.keys(graph.nodes || {}))
                    nodeGraphs[id] = graphIndex
                connections.push(...(graph.connections || []))
            }
            passiveTreeData = data
            treeNodes = nodes
            nodeGraphIndices = nodeGraphs
            treeConnections = connections
            treeDataError = ""
            if (!hasStoredViewerState || storedCameraTreeKey !== currentTreeKey)
                Qt.callLater(focusTreeChanges)
            treeCanvas.requestPaint()
        } catch (error) {
            treeDataError = "Could not read passive tree data"
            console.warn("Could not load passive tree data:", error)
        }
    }

    function fetchMissingTreeData(version) {
        if (!version || treeDownloadProcess.running || attemptedTreeDownloads.includes(version))
            return
        attemptedTreeDownloads.push(version)
        pendingTreeVersion = version
        treeDownloadError = ""
        treeDataError = `Tree ${version} is not bundled; checking GitHub...`
        treeDownloadProcess.command = [
            treePythonPath,
            Quickshell.shellDir + "/seed_passive_tree.py",
            "--ensure",
            version,
            treeCacheDir,
        ]
        treeDownloadProcess.running = true
    }

    function fitTreeToIds(nodeIds) {
        if (!passiveTreeData || !treeCanvas.width || !treeCanvas.height)
            return
        const ids = nodeIds && nodeIds.length ? nodeIds : Object.keys(treeNodes)
        let minX = Infinity
        let minY = Infinity
        let maxX = -Infinity
        let maxY = -Infinity
        for (const id of ids) {
            const node = treeNodes[id]
            if (!node)
                continue
            minX = Math.min(minX, node.x)
            minY = Math.min(minY, node.y)
            maxX = Math.max(maxX, node.x)
            maxY = Math.max(maxY, node.y)
        }
        if (!Number.isFinite(minX)) {
            minX = passiveTreeData.bounds.minX
            minY = passiveTreeData.bounds.minY
            maxX = passiveTreeData.bounds.maxX
            maxY = passiveTreeData.bounds.maxY
        }
        const padding = 1250
        const width = Math.max(2500, maxX - minX + padding * 2)
        const height = Math.max(2500, maxY - minY + padding * 2)
        treeCenterX = (minX + maxX) / 2
        treeCenterY = (minY + maxY) / 2
        treeScale = Math.min((treeCanvas.width - 24) / width, (treeCanvas.height - 24) / height)
        treeCanvas.requestPaint()
    }

    function focusTreeChanges() {
        if (!passiveTreeData || !selectedTree)
            return
        const changes = treeDelta.added.concat(treeDelta.removed)
        fitTreeToIds(changes.length ? changes : treeDelta.active)
    }

    function nodeRadius(node) {
        switch (node.k) {
        case "Keystone": return 75
        case "Notable":
        case "Jewel": return 60
        case "Mastery": return 50
        case "Ascendancy_Start": return 35
        default: return 40
        }
    }

    function nodeState(id) {
        if (addedNodeIds.has(id))
            return "added"
        if (removedNodeIds.has(id))
            return "removed"
        if (activeNodeIds.has(id))
            return "active"
        return "base"
    }

    function selectedAscendancyGraph() {
        if (!passiveTreeData || !selectedTree || Number(selectedTree.ascendancyId) < 1)
            return -1
        const characterClass = passiveTreeData.classes[Number(selectedTree.classId)]
        if (!characterClass)
            return -1
        const ascendancyName = characterClass.ascendancies[Number(selectedTree.ascendancyId) - 1]
        const ascendancy = passiveTreeData.ascendancies[ascendancyName]
        return ascendancy ? ascendancy.graphIndex : -1
    }

    function edgeColor(connection) {
        const state = TreeView.connectionState(nodeState(connection.a), nodeState(connection.b))
        if (state === "active")
            return "#168fc4"
        if (state === "added")
            return "#24b944"
        if (state === "removed")
            return "#c7353b"
        return "#48515a"
    }

    function drawConnection(context, connection, nodeA, nodeB, toScreenX, toScreenY) {
        const x1 = toScreenX(nodeA.x)
        const y1 = toScreenY(nodeA.y)
        const x2 = toScreenX(nodeB.x)
        const y2 = toScreenY(nodeB.y)
        context.beginPath()
        if (!connection.s) {
            context.moveTo(x1, y1)
            context.lineTo(x2, y2)
            return
        }

        const radius = connection.s.r * treeScale
        const dx = x2 - x1
        const dy = y2 - y1
        const distance = Math.sqrt(dx * dx + dy * dy)
        if (!radius || distance > radius * 2 || distance === 0) {
            context.moveTo(x1, y1)
            context.lineTo(x2, y2)
            return
        }

        const halfDistance = distance / 2
        const offset = Math.sqrt(Math.max(0, radius * radius - halfDistance * halfDistance))
        const middleX = (x1 + x2) / 2
        const middleY = (y1 + y2) / 2
        const perpendicularX = -dy / distance
        const perpendicularY = dx / distance
        const candidates = [
            { x: middleX + perpendicularX * offset, y: middleY + perpendicularY * offset },
            { x: middleX - perpendicularX * offset, y: middleY - perpendicularY * offset },
        ]
        const clockwise = connection.s.w === "CW"
        let center = candidates[0]
        let startAngle = 0
        let endAngle = 0
        for (const candidate of candidates) {
            const candidateStart = Math.atan2(y1 - candidate.y, x1 - candidate.x)
            const candidateEnd = Math.atan2(y2 - candidate.y, x2 - candidate.x)
            const sweep = clockwise
                ? (candidateEnd - candidateStart + Math.PI * 2) % (Math.PI * 2)
                : (candidateStart - candidateEnd + Math.PI * 2) % (Math.PI * 2)
            if (sweep <= Math.PI + 0.001) {
                center = candidate
                startAngle = candidateStart
                endAngle = candidateEnd
                break
            }
        }
        context.arc(center.x, center.y, radius, startAngle, endAngle, !clockwise)
    }

    function paintTree(context) {
        context.reset()
        context.globalCompositeOperation = "source-over"
        context.clearRect(0, 0, treeCanvas.width, treeCanvas.height)
        if (!passiveTreeData || !selectedTree)
            return
        const toScreenX = x => (x - treeCenterX) * treeScale + treeCanvas.width / 2
        const toScreenY = y => (y - treeCenterY) * treeScale + treeCanvas.height / 2
        const activeAscendancyGraph = selectedAscendancyGraph()

        context.lineCap = "round"
        for (const connection of treeConnections) {
            const a = treeNodes[connection.a]
            const b = treeNodes[connection.b]
            if (!a || !b)
                continue
            drawConnection(context, connection, a, b, toScreenX, toScreenY)
            context.strokeStyle = edgeColor(connection)
            const graphIndex = nodeGraphIndices[connection.a]
            const dimmed = activeAscendancyGraph >= 0 && graphIndex > 0 && graphIndex !== activeAscendancyGraph
            context.globalAlpha = (edgeColor(connection) === "#48515a" ? 0.62 : 0.95) * (dimmed ? 0.4 : 1)
            context.lineWidth = Math.max(1, (nodeState(connection.a) === "base" && nodeState(connection.b) === "base" ? 16 : 28) * treeScale)
            context.stroke()
        }
        context.globalAlpha = 1

        for (const id of Object.keys(treeNodes)) {
            const node = treeNodes[id]
            const state = nodeState(id)
            const graphIndex = nodeGraphIndices[id]
            const dimmed = activeAscendancyGraph >= 0 && graphIndex > 0 && graphIndex !== activeAscendancyGraph
            const color = state === "added" ? "#25ed45"
                : state === "removed" ? "#ff3e42"
                : state === "active" ? "#2561ff" : "#64717e"
            const radius = Math.max(1.2, nodeRadius(node) * treeScale)
            const x = toScreenX(node.x)
            const y = toScreenY(node.y)
            context.beginPath()
            context.arc(x, y, radius, 0, Math.PI * 2)
            context.globalCompositeOperation = "source-over"
            context.fillStyle = color
            context.strokeStyle = state === "base" ? "#9aa5b1" : color
            context.globalAlpha = (state === "base" ? 0.74 : 1) * (dimmed ? 0.4 : 1)
            context.fill()
            context.lineWidth = Math.max(1, 2 * treeScale)
            context.stroke()
        }
        context.globalAlpha = 1
    }

    function findNodeAt(x, y) {
        if (!passiveTreeData)
            return null
        let closest = null
        let closestDistance = Infinity
        for (const id of Object.keys(treeNodes)) {
            const node = treeNodes[id]
            const sx = (node.x - treeCenterX) * treeScale + treeCanvas.width / 2
            const sy = (node.y - treeCenterY) * treeScale + treeCanvas.height / 2
            const dx = sx - x
            const dy = sy - y
            const distance = dx * dx + dy * dy
            const hitRadius = Math.max(9, nodeRadius(node) * treeScale + 4)
            if (distance <= hitRadius * hitRadius && distance < closestDistance) {
                closest = { id: id, node: node }
                closestDistance = distance
            }
        }
        return closest
    }

    function masteryDescription(nodeId) {
        const effectId = selectedTree && selectedTree.masteries ? selectedTree.masteries[nodeId] : null
        const effect = effectId && passiveTreeData ? passiveTreeData.masteryEffects[effectId] : null
        return effect ? effect.stats.join("\n") : ""
    }

    function stepTree(delta) {
        selectedTreeIndex = Math.max(0, Math.min(treeSpecs.length - 1, selectedTreeIndex + delta))
    }

    function stepGems(delta) {
        selectedGemIndex = Math.max(0, Math.min(skillSets.length - 1, selectedGemIndex + delta))
        Qt.callLater(clampViewerHeight)
    }

    function gemColor(gem) {
        const info = gemData[gem.id] || {}
        const colors = { strength: "#ff3333", dexterity: "#33ff33", intelligence: "#3333ff" }
        return colors[info.primary_attribute] || "#d8d5ca"
    }

    FileView {
        id: viewerStateFile
        path: (Quickshell.env("POE_OVERLAY_STATE_DIR")
            || (Quickshell.env("XDG_STATE_HOME")
                ? Quickshell.env("XDG_STATE_HOME") + "/poe-overlay"
                : Quickshell.env("HOME") + "/.local/state/poe-overlay")) + "/viewer_state.json"
        preload: true
        blockLoading: true
        printErrors: false
        onLoaded: root.restoreViewerState()
        onLoadFailed: {
            root.viewerStateLoaded = true
            root.resetViewer()
        }
    }

    Timer {
        id: viewerStateSaveTimer
        interval: 300
        repeat: false
        onTriggered: root.saveViewerState()
    }

    Timer {
        id: focusRefreshTimer
        interval: 200
        repeat: false
        onTriggered: {
            root.keyboardFocusRequested = false
            Qt.callLater(() => {
                if (root.viewerVisible)
                    root.keyboardFocusRequested = true
            })
        }
    }

    Timer {
        id: treeCanvasRefreshTimer
        interval: 60
        repeat: false
        onTriggered: root.refreshTreeCanvas()
    }

    FileView {
        id: treeDataFile
        path: root.selectedTree && root.selectedTree.version
            ? root.cachedTreeVersion === root.selectedTree.version && root.cachedTreePath
                ? root.cachedTreePath
                : Qt.resolvedUrl("routes/passive-tree/" + root.selectedTree.version + ".json")
            : ""
        preload: true
        printErrors: false
        onLoaded: root.loadTreeData()
        onLoadFailed: {
            if (root.selectedTree && root.selectedTree.version)
                root.fetchMissingTreeData(root.selectedTree.version)
            else
                root.treeDataError = "This build has no passive tree version"
        }
    }

    Process {
        id: treeDownloadProcess
        stdout: StdioCollector {
            onStreamFinished: {
                const path = text.trim()
                if (path) {
                    root.cachedTreeVersion = root.pendingTreeVersion
                    root.cachedTreePath = path
                    root.treeDataError = ""
                }
            }
        }
        stderr: StdioCollector {
            onStreamFinished: root.treeDownloadError = text.trim()
        }
        onExited: (exitCode, exitStatus) => {
            if (exitCode !== 0) {
                root.treeDataError = root.treeDownloadError
                    || `Could not download tree data for ${root.pendingTreeVersion}`
                console.warn("Passive tree download failed:", root.treeDataError)
            }
            if (root.selectedTree && root.selectedTree.version !== root.pendingTreeVersion)
                Qt.callLater(() => root.fetchMissingTreeData(root.selectedTree.version))
        }
    }

    FileView {
        id: gemFile
        path: Qt.resolvedUrl("routes/gems.json")
        preload: true
        blockLoading: true
        printErrors: false
        onLoaded: {
            try {
                root.gemData = JSON.parse(text())
            } catch (error) {
                root.gemData = ({})
            }
        }
    }

    Rectangle {
        anchors.fill: parent
                color: "#66101010"
        border.color: "#4d4a3e"
        border.width: 1

        Column {
            id: content
            x: 4
            y: 4
            width: parent.width - 8
            height: parent.height - 8
            spacing: 4

            Row {
                width: parent.width
                    height: 28
                spacing: 2

                Repeater {
                    model: ["Tree", "Gems", "All"]
                    delegate: Button {
                        required property int index
                        required property string modelData
                        width: 90
                        height: 28
                        text: modelData
                        onClicked: root.viewMode = index
                        contentItem: Text {
                            text: parent.text
                            color: root.viewMode === index ? "#f2eee6" : "#aaa99e"
                            font.pixelSize: 13
                            font.weight: root.viewMode === index ? Font.DemiBold : Font.Normal
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                        background: Rectangle {
                            color: root.viewMode === index ? "#34382f" : "#1c1f1b"
                            border.color: root.viewMode === index ? "#d8a85e" : "#41463d"
                            radius: 3
                        }
                    }
                }

                Button {
                    text: "×"
                    width: 32
                    height: 28
                    onClicked: root.closeRequested()
                    contentItem: Text { text: parent.text; color: "#d8d5ca"; font.pixelSize: 18; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                    background: Rectangle { color: parent.hovered ? "#352522" : "#1c1f1b"; border.color: "#70413b"; radius: 3 }
                }
            }

            Item {
                id: treePanel
                visible: root.treeVisible
                width: content.width
                height: root.gemsVisible
                    ? Math.max(210, content.height - gemsPanel.height - 47)
                    : content.height - 38

                Rectangle {
                    anchors.fill: parent
                    color: "#aa101010"
                    border.color: "#333a3f"
                    radius: 3
                }

                Column {
                    id: treePanelContent
                    anchors.fill: parent
                    spacing: 2

                    Row {
                    width: parent.width
                    height: 32
                    spacing: 2

                    Button {
                        text: "‹"
                        enabled: root.selectedTreeIndex > 0
                        width: 120
                        height: 24
                        onClicked: root.stepTree(-1)
                        contentItem: Text { text: parent.text; color: "#eee9df"; font.pixelSize: 16; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                        background: Rectangle { color: parent.hovered ? "#30332c" : "#22251f"; border.color: "#4d4a3e"; radius: 3 }
                    }

                    Text {
                        width: parent.width - 244
                        height: parent.height
                        text: root.selectedTree ? root.selectedTree.title : "No tree loadouts"
                        color: "#d6d2c8"
                        font.pixelSize: 12
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        elide: Text.ElideRight
                    }

                    Button {
                        text: "›"
                        enabled: root.selectedTreeIndex + 1 < root.treeSpecs.length
                        width: 120
                        height: 24
                        onClicked: root.stepTree(1)
                        contentItem: Text { text: parent.text; color: "#eee9df"; font.pixelSize: 16; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                        background: Rectangle { color: parent.hovered ? "#30332c" : "#22251f"; border.color: "#4d4a3e"; radius: 3 }
                    }
                }

                    Item {
                    width: parent.width
                    height: parent.height - 33

                    Canvas {
                        id: treeCanvas
                        anchors.fill: parent
                        renderStrategy: Canvas.Threaded
                        onPaint: root.paintTree(getContext("2d"))
                        onWidthChanged: treeCanvasRefreshTimer.restart()
                        onHeightChanged: treeCanvasRefreshTimer.restart()
                        onVisibleChanged: if (visible) Qt.callLater(root.refreshTreeCanvas)
                        Component.onCompleted: Qt.callLater(root.refreshTreeCanvas)
                    }

                    Rectangle {
                        visible: root.treeSpecs.length === 0
                        anchors.centerIn: parent
                        width: Math.min(parent.width - 32, 280)
                        height: emptyTreeText.implicitHeight + 20
                        color: "#e6171916"
                        border.color: "#4a5047"
                        radius: 3

                        Text {
                            id: emptyTreeText
                            anchors.fill: parent
                            anchors.margins: 10
                            text: "Re-import the PoB code to load passive tree specs."
                            color: "#d2d0c7"
                            font.pixelSize: 12
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                            wrapMode: Text.Wrap
                        }
                    }

                    MouseArea {
                        id: treeMouse
                        anchors.fill: parent
                        acceptedButtons: Qt.LeftButton
                        hoverEnabled: true
                        preventStealing: true
                        cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                        property real lastX: 0
                        property real lastY: 0

                        onPressed: mouse => {
                            lastX = mouse.x
                            lastY = mouse.y
                        }
                        onPositionChanged: mouse => {
                            if (pressed) {
                                root.treeCenterX -= (mouse.x - lastX) / root.treeScale
                                root.treeCenterY -= (mouse.y - lastY) / root.treeScale
                                lastX = mouse.x
                                lastY = mouse.y
                                treeCanvas.requestPaint()
                            } else {
                                root.hoveredNode = root.findNodeAt(mouse.x, mouse.y)
                            }
                        }
                        onWheel: wheel => {
                            const oldScale = root.treeScale
                            const worldX = root.treeCenterX + (wheel.x - width / 2) / oldScale
                            const worldY = root.treeCenterY + (wheel.y - height / 2) / oldScale
                            const factor = Math.pow(1.0015, wheel.angleDelta.y)
                            root.treeScale = Math.max(0.00015, Math.min(4, oldScale * factor))
                            root.treeCenterX = worldX - (wheel.x - width / 2) / root.treeScale
                            root.treeCenterY = worldY - (wheel.y - height / 2) / root.treeScale
                            treeCanvas.requestPaint()
                            wheel.accepted = true
                        }
                        onExited: root.hoveredNode = null
                    }

                    Rectangle {
                        visible: !!root.hoveredNode
                        x: 6
                        y: 6
                        width: Math.min(parent.width - 12, 232)
                        height: Math.min(parent.height - 12, tooltipContent.implicitHeight + 20)
                        color: "#f0151716"
                        border.color: "#756342"
                        radius: 3

                        Column {
                            id: tooltipContent
                            x: 10
                            y: 8
                            width: parent.width - 20
                            spacing: 4

                            Text {
                                width: parent.width
                                text: root.hoveredNode ? root.hoveredNode.node.text : ""
                                color: "#f0c674"
                                font.pixelSize: 13
                                font.weight: Font.DemiBold
                                wrapMode: Text.Wrap
                            }

                            Text {
                                width: parent.width
                                text: root.hoveredNode
                                    ? (root.hoveredNode.node.stats || []).concat(root.masteryDescription(root.hoveredNode.id) ? [root.masteryDescription(root.hoveredNode.id)] : []).join("\n")
                                    : ""
                                color: "#e4e0d6"
                                font.pixelSize: 11
                                wrapMode: Text.Wrap
                            }
                        }
                    }
                }

                    Text {
                        visible: root.treeDataError.length > 0
                        width: parent.width
                        text: root.treeDataError
                        color: "#d7bd85"
                        font.pixelSize: 11
                        wrapMode: Text.Wrap
                    }
                }
            }

            Rectangle {
                visible: root.treeVisible && root.gemsVisible
                width: parent.width
                height: 1
                color: "#49463d"
            }

            Item {
                id: gemsPanel
                visible: root.gemsVisible
                width: content.width
                height: root.treeVisible
                    ? Math.min(gemGroups.implicitHeight + 35, content.height - 257)
                    : content.height - 38

                Rectangle {
                    anchors.fill: parent
                    color: "#99101010"
                    border.color: "#4d4a3e"
                    radius: 3
                }

                Column {
                    anchors.fill: parent
                    spacing: 2

                    Row {
                        width: parent.width
                        height: 32
                        spacing: 2

                    Button {
                        text: "‹"
                        enabled: root.selectedGemIndex > 0
                        width: 120
                        height: 24
                        onClicked: root.stepGems(-1)
                        contentItem: Text { text: parent.text; color: "#eee9df"; font.pixelSize: 16; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                        background: Rectangle { color: parent.hovered ? "#30332c" : "#22251f"; border.color: "#4d4a3e"; radius: 3 }
                    }

                    Text {
                        width: parent.width - 244
                        height: parent.height
                        text: root.selectedSkillSet ? root.selectedSkillSet.title : "No gem loadouts"
                        color: "#d6d2c8"
                        font.pixelSize: 13
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        elide: Text.ElideRight
                    }

                    Button {
                        text: "›"
                        enabled: root.selectedGemIndex + 1 < root.skillSets.length
                        width: 120
                        height: 24
                        onClicked: root.stepGems(1)
                        contentItem: Text { text: parent.text; color: "#eee9df"; font.pixelSize: 16; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                        background: Rectangle { color: parent.hovered ? "#30332c" : "#22251f"; border.color: "#4d4a3e"; radius: 3 }
                    }
                }

                    Flickable {
                        id: gemList
                        width: parent.width
                        height: parent.height - 35
                        contentWidth: width
                        contentHeight: gemGroups.implicitHeight
                        clip: true

                        ScrollBar.vertical: ScrollBar {
                            policy: ScrollBar.AsNeeded
                            width: 8

                            contentItem: Rectangle {
                                implicitWidth: 6
                                radius: 3
                                color: parent.pressed ? "#d8a85e" : parent.hovered ? "#a98a5b" : "#756342"
                            }
                        }

                        GridLayout {
                            id: gemGroups
                            width: parent.width
                            columns: 2
                            columnSpacing: 8
                            rowSpacing: 10
                            onImplicitHeightChanged: Qt.callLater(root.clampViewerHeight)

                        Repeater {
                            model: root.selectedSkillSet ? root.selectedSkillSet.groups : []
                            delegate: Item {
                                required property var modelData
                                required property int index
                                Layout.fillWidth: true
                                Layout.minimumWidth: 0
                                implicitHeight: groupContent.implicitHeight

                                Column {
                                    id: groupContent
                                    width: parent.width
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 2

                                    Repeater {
                                        model: modelData.gems
                                        delegate: RowLayout {
                                            required property var modelData
                                            Layout.fillWidth: true
                                            Layout.minimumWidth: 0
                                            spacing: 4

                                            Item {
                                                Layout.preferredWidth: modelData.support ? 10 : 0
                                                Layout.minimumWidth: modelData.support ? 10 : 0
                                                Layout.preferredHeight: 1
                                            }

                                            Rectangle {
                                                Layout.preferredWidth: 10
                                                Layout.preferredHeight: 10
                                                Layout.alignment: Qt.AlignVCenter
                                                radius: 5
                                                color: root.gemColor(modelData)
                                            }

                                            Text {
                                                Layout.fillWidth: true
                                                Layout.minimumWidth: 0
                                                text: modelData.name
                                                color: "#e9e6de"
                                                font.pixelSize: 13
                                                wrapMode: Text.Wrap
                                            }
                                        }
                                    }

                                    Rectangle {
                                        visible: index + 1 < root.selectedSkillSet.groups.length
                                        width: parent.width
                                        height: 1
                                        color: "#55534c"
                                    }
                                }
                            }
                        }
                        }
                    }
                }
            }
        }

        Item {
            id: resizeGrip
            width: 30
            height: 30
            anchors.left: parent.left
            anchors.bottom: parent.bottom

            HoverHandler {
                cursorShape: Qt.SizeBDiagCursor
            }

            DragHandler {
                id: resizeHandler
                target: null
                property real startWidth: 0
                property real startHeight: 0
                property real startGlobalX: 0
                property real startGlobalY: 0

                onActiveChanged: {
                    if (active) {
                        startWidth = root.viewerWidth
                        startHeight = root.viewerHeight
                        const pointer = root.resizePointerGlobalPosition()
                        startGlobalX = pointer.x
                        startGlobalY = pointer.y
                    }
                }
                onActiveTranslationChanged: {
                    if (!active)
                        return
                    const pointer = root.resizePointerGlobalPosition()
                    root.viewerWidth = Math.max(320, Math.min(Screen.width - 48, startWidth - (pointer.x - startGlobalX)))
                    root.viewerHeight = Math.max(root.minimumViewerHeight, Math.min(Screen.height - 48, startHeight + (pointer.y - startGlobalY)))
                    treeCanvas.requestPaint()
                }
            }

            Canvas {
                anchors.fill: parent
                onPaint: {
                    const context = getContext("2d")
                    context.clearRect(0, 0, width, height)
                    context.strokeStyle = "#8b8068"
                    context.lineWidth = 1.5
                    context.lineCap = "round"
                    for (let index = 0; index < 3; index++) {
                        const startX = 4 + index * 5
                        const startY = height - 4
                        context.beginPath()
                        context.moveTo(startX, startY)
                        context.lineTo(startX + 7, startY - 7)
                        context.stroke()
                    }
                }
            }
        }
    }
}
