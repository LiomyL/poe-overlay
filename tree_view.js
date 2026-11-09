function compareTrees(currentTree, previousTree) {
    const currentNodes = new Set(currentTree ? currentTree.nodes : [])
    const previousNodes = new Set(previousTree ? previousTree.nodes : [])
    const currentMasteries = currentTree ? currentTree.masteries || {} : {}
    const previousMasteries = previousTree ? previousTree.masteries || {} : {}

    for (const [nodeId, effectId] of Object.entries(currentMasteries)) {
        if (previousMasteries[nodeId] !== effectId)
            previousNodes.delete(nodeId)
    }

    const active = []
    const added = []
    const removed = []
    for (const nodeId of currentNodes) {
        if (previousNodes.has(nodeId))
            active.push(nodeId)
        else
            added.push(nodeId)
    }
    for (const nodeId of previousNodes) {
        if (!currentNodes.has(nodeId))
            removed.push(nodeId)
    }

    return { active, added, removed }
}

function connectionState(a, b) {
    if (a === "active" && b === "active")
        return "active"
    if ((a === "added" && (b === "added" || b === "active"))
        || (b === "added" && (a === "added" || a === "active")))
        return "added"
    if ((a === "removed" && (b === "removed" || b === "active"))
        || (b === "removed" && (a === "removed" || a === "active")))
        return "removed"
    return "base"
}

if (typeof module !== "undefined" && module.exports)
    module.exports = { compareTrees, connectionState }
