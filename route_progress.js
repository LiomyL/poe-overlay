function resolveAutoStep(routeActs, actIndex, areaId, previousAreaId, cursorAct, cursorStep, areas = {}) {
    let act = cursorAct
    let step = cursorStep
    let matched = false

    if (isCampaignStartTransition(routeActs, actIndex, areaId, previousAreaId))
        return { act: 0, step: 1, matched: true }

    if (areaId === "1_1_1" && (cursorAct > 0 || cursorStep > 0))
        return { act: 0, step: 0, matched: true }

    let selectedCandidate = -1
    let selectedCandidateAct = -1
    const cursorRows = cursorAct >= 0 && routeActs[cursorAct] ? routeActs[cursorAct].rows : []
    const expectedIndex = cursorStep >= 0 ? cursorStep : -1
    if (expectedIndex >= 0 && cursorRows[expectedIndex]
        && cursorRows[expectedIndex].destinationAreaId === areaId) {
        selectedCandidate = expectedIndex
        selectedCandidateAct = cursorAct
    }

    if (selectedCandidate < 0 && (actIndex < 0 || !routeActs[actIndex]))
        return { act, step, matched }

    const rows = routeActs[actIndex] ? routeActs[actIndex].rows : []

    for (let index = 0; selectedCandidate < 0 && index < rows.length - 1; index++) {
        if (rows[index].destinationAreaId !== areaId)
            continue
        const returningToExpectedTown = areas[areaId] && areas[areaId].is_town_area
            && cursorAct === actIndex && index + 1 === cursorStep
        if (previousAreaId) {
            if (!returningToExpectedTown && index > 0 && rows[index - 1].destinationAreaId !== previousAreaId)
                continue
            if (!returningToExpectedTown && index === 0) {
                if (actIndex === 0 || actIndex !== cursorAct + 1)
                    continue
                const previousRows = routeActs[actIndex - 1].rows
                const previousDestination = [...previousRows].reverse()
                    .find(row => row.destinationAreaId)?.destinationAreaId
                if (previousDestination !== previousAreaId)
                    continue
            }
        }
        if (cursorAct === actIndex && cursorStep >= 0
            && index !== cursorStep && !returningToExpectedTown)
            continue
        if (cursorAct > actIndex)
            continue

        selectedCandidate = index
        selectedCandidateAct = actIndex
        break
    }

    if (selectedCandidate < 0 && cursorStep < 0 && cursorAct < 0) {
        for (let index = 0; index < rows.length - 1; index++) {
            if (rows[index].destinationAreaId === areaId) {
                selectedCandidate = index
                selectedCandidateAct = actIndex
                break
            }
        }
    }

    if (selectedCandidate >= 0) {
        act = selectedCandidateAct
        step = selectedCandidate + 1
        matched = true
    } else if (areaId === "1_1_1" && cursorStep < 0) {
        act = 0
        step = 0
        matched = true
    }

    return { act, step, matched }
}

function shiftRouteCursor(routeActs, cursorAct, cursorStep, delta) {
    const steps = []
    for (let act = 0; act < routeActs.length; act++) {
        const rows = routeActs[act].rows || []
        for (let step = 0; step < rows.length; step++)
            steps.push({ act, step })
    }
    if (!steps.length)
        return null

    let cursorIndex = steps.findIndex(position => position.act === cursorAct && position.step === cursorStep)
    if (cursorIndex < 0)
        cursorIndex = delta < 0 ? steps.length : -1
    const nextIndex = Math.max(0, Math.min(steps.length - 1, cursorIndex + Math.sign(delta)))
    return steps[nextIndex]
}

function isCampaignStartTransition(routeActs, actIndex, areaId, previousAreaId) {
    const firstRow = routeActs[0] && routeActs[0].rows[0]
    return actIndex === 0 && !!firstRow
        && areaId === firstRow.destinationAreaId
        && previousAreaId === firstRow.sourceAreaId
}

function findPausedStep(routeActs, actIndex, areaId, cursorAct, cursorStep) {
    const cursorExists = cursorAct >= 0 && cursorStep >= 0
        && routeActs[cursorAct] && routeActs[cursorAct].rows[cursorStep]
    if (actIndex < 0 || !routeActs[actIndex])
        return cursorExists ? { act: cursorAct, step: cursorStep } : null
    if (cursorAct >= 0 && actIndex > cursorAct)
        return cursorExists ? { act: cursorAct, step: cursorStep } : null

    const rows = routeActs[actIndex].rows
    for (let index = rows.length - 1; index >= 0; index--) {
        if (rows[index].sourceAreaId !== areaId)
            continue
        if (actIndex === cursorAct && cursorStep >= 0 && index > cursorStep)
            continue
        return { act: actIndex, step: index }
    }
    return cursorExists ? { act: cursorAct, step: cursorStep } : null
}

function findLocalStep(routeActs, actIndex, areaId, cursorAct, cursorStep) {
    if (actIndex < 0 || !routeActs[actIndex] || cursorAct >= 0 && actIndex > cursorAct)
        return null

    const rows = routeActs[actIndex].rows
    for (let index = rows.length - 1; index >= 0; index--) {
        if (rows[index].sourceAreaId !== areaId)
            continue
        if (actIndex === cursorAct && cursorStep >= 0 && index > cursorStep)
            continue
        return { act: actIndex, step: index }
    }
    return null
}

function findRecoveryStep(routeActs, areas, recoveryTargetAreaId, cursorAct, cursorStep) {
    if (!recoveryTargetAreaId)
        return null
    const area = areas[recoveryTargetAreaId]
    const lastRelevantAct = cursorAct >= 0
        ? Math.min(cursorAct, routeActs.length - 1)
        : area ? area.act - 1 : -1
    for (let act = lastRelevantAct; act >= 0; act--) {
        const rows = routeActs[act].rows
        for (let step = rows.length - 1; step >= 0; step--) {
            if (act === cursorAct && cursorStep >= 0 && step > cursorStep)
                continue
            if (rows[step].sourceAreaId === recoveryTargetAreaId)
                return { act, step }
        }
    }
    return null
}

function resolveNextRouteStep(routeActs, cursorAct, cursorStep, recoveryTargetAreaId, areas = {}) {
    let baseStep = { act: cursorAct, step: cursorStep }
    if (recoveryTargetAreaId) {
        baseStep = findRecoveryStep(routeActs, areas, recoveryTargetAreaId, cursorAct, cursorStep)
        if (!baseStep)
            return null
    }

    if (baseStep.act < 0 || baseStep.step < 0 || !routeActs[baseStep.act])
        return null
    const currentRows = routeActs[baseStep.act].rows || []
    if (currentRows[baseStep.step + 1])
        return { act: baseStep.act, step: baseStep.step + 1 }
    for (let act = baseStep.act + 1; act < routeActs.length; act++) {
        if (routeActs[act].rows && routeActs[act].rows.length)
            return { act, step: 0 }
    }
    return null
}

function resolveRecoveryStep(routeActs, areas, areaId, recoveryTargetAreaId, cursorAct, cursorStep) {
    if (!recoveryTargetAreaId || areaId !== recoveryTargetAreaId)
        return null
    return findRecoveryStep(routeActs, areas, recoveryTargetAreaId, cursorAct, cursorStep)
}

function updateRecoveryTarget(areas, previousAreaId, areaId, progressMatched, recoveryTargetAreaId, routeTargetAreaId, campaignStartTransition) {
    if (campaignStartTransition)
        return ""
    if (recoveryTargetAreaId) {
        if (areaId === recoveryTargetAreaId || progressMatched)
            return ""
        return recoveryTargetAreaId
    }
    if (progressMatched)
        return ""

    if (routeTargetAreaId && routeTargetAreaId !== areaId)
        return routeTargetAreaId

    const previousArea = areas[previousAreaId]
    const currentArea = areas[areaId]
    if (previousArea && !previousArea.is_town_area && currentArea && currentArea.is_town_area)
        return previousAreaId
    return recoveryTargetAreaId
}

function checkpointMatches(checkpoint, expected, routeActs) {
    return !!checkpoint
        && (checkpoint.version === 1 || checkpoint.version === 2)
        && checkpoint.buildKey === expected.buildKey
        && checkpoint.routeFingerprint === expected.routeFingerprint
        && checkpoint.routeMode === expected.routeMode
        && checkpoint.bandit === expected.bandit
        && !!routeActs[checkpoint.act]
        && !!routeActs[checkpoint.act].rows[checkpoint.step]
}

if (typeof module !== "undefined" && module.exports)
    module.exports = {
        resolveAutoStep,
        shiftRouteCursor,
        isCampaignStartTransition,
        findPausedStep,
        findLocalStep,
        findRecoveryStep,
        resolveNextRouteStep,
        resolveRecoveryStep,
        updateRecoveryTarget,
        checkpointMatches,
    }
