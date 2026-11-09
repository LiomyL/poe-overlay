const assert = require("node:assert/strict")
const test = require("node:test")
const {
    checkpointMatches,
    findLocalStep,
    findPausedStep,
    findRecoveryStep,
    resolveRecoveryStep,
    resolveAutoStep,
    shiftRouteCursor,
    updateRecoveryTarget,
} = require("../route_progress.js")

const route = [{
    rows: [
        { destinationAreaId: "1_1_town" },
        { destinationAreaId: "1_1_2" },
        { destinationAreaId: "1_1_3" },
        { destinationAreaId: "1_1_4_1" },
        { destinationAreaId: "1_1_5" },
        { destinationAreaId: "1_1_town" },
        { destinationAreaId: "1_1_8" },
    ],
}]

test("off-route hideout and return to repeated town preserve the cursor", () => {
    const cursor = { act: 0, step: 2 }
    const hideout = resolveAutoStep(route, -1, "HideoutLibrary", "1_1_2", cursor.act, cursor.step)
    assert.deepEqual(hideout, { act: 0, step: 2, matched: false })

    const returnToTown = resolveAutoStep(route, 0, "1_1_town", "HideoutLibrary", hideout.act, hideout.step)
    assert.deepEqual(returnToTown, { act: 0, step: 2, matched: false })
})

test("progress resumes on the next matching route transition", () => {
    const resumed = resolveAutoStep(route, 0, "1_1_3", "1_1_2", 0, 2)
    assert.deepEqual(resumed, { act: 0, step: 3, matched: true })
})

test("manual cursor shifts across acts and remains at valid route endpoints", () => {
    const acts = [
        { rows: [{}, {}] },
        { rows: [{}] },
    ]

    assert.deepEqual(shiftRouteCursor(acts, 0, 1, 1), { act: 1, step: 0 })
    assert.deepEqual(shiftRouteCursor(acts, 1, 0, -1), { act: 0, step: 1 })
    assert.deepEqual(shiftRouteCursor(acts, 0, 0, -1), { act: 0, step: 0 })
    assert.deepEqual(shiftRouteCursor(acts, 1, 0, 1), { act: 1, step: 0 })
    assert.deepEqual(shiftRouteCursor(acts, -1, -1, 1), { act: 0, step: 0 })
})

test("a matching predecessor resolves repeated destinations without regressing", () => {
    const resumed = resolveAutoStep(
        route,
        0,
        "1_1_town",
        "1_1_5",
        0,
        6,
        { "1_1_town": { is_town_area: true } },
    )
    assert.deepEqual(resumed, { act: 0, step: 6, matched: true })
})

test("a stale repeated area event cannot rewind the route cursor", () => {
    const acts = [{
        rows: [
            { sourceAreaId: "Start", destinationAreaId: "Town" },
            { sourceAreaId: "Town", destinationAreaId: "AreaA" },
            { sourceAreaId: "AreaA", destinationAreaId: "AreaB" },
            { sourceAreaId: "AreaB", destinationAreaId: "Town" },
            { sourceAreaId: "Town", destinationAreaId: "AreaA" },
            { sourceAreaId: "AreaA", destinationAreaId: "AreaC" },
        ]
    }]

    const staleEvent = resolveAutoStep(acts, 0, "AreaA", "Town", 0, 5)

    assert.deepEqual(staleEvent, { act: 0, step: 5, matched: false })
})

test("Coast to Lioneye's Watch does not jump to a later town visit", () => {
    const act = [{
        rows: [
            { destinationAreaId: "1_1_town" },
            { destinationAreaId: "1_1_2" },
            { destinationAreaId: "1_1_3" },
            { destinationAreaId: "1_1_4_1" },
            { destinationAreaId: "1_1_2" },
            { destinationAreaId: "1_1_2a" },
            { destinationAreaId: "1_1_town" },
            { destinationAreaId: "1_1_7_1" },
        ],
    }]

    const returnedToTown = resolveAutoStep(act, 0, "1_1_town", "1_1_2", 0, 2)
    assert.deepEqual(returnedToTown, { act: 0, step: 2, matched: false })
})

test("entering the expected destination from another area resumes without requiring the prescribed predecessor", () => {
    const resumed = resolveAutoStep(route, 0, "1_1_3", "HideoutLibrary", 0, 2)
    assert.deepEqual(resumed, { act: 0, step: 3, matched: true })
})

test("the first observed area initializes the cursor once", () => {
    const initialized = resolveAutoStep(route, 0, "1_1_town", "1_1_1", -1, -1)
    assert.deepEqual(initialized, { act: 0, step: 1, matched: true })
})

test("new character entering town from the Strand resets a stale campaign cursor", () => {
    const acts = [{
        rows: [
            { sourceAreaId: "1_1_1", destinationAreaId: "1_1_town" },
            { sourceAreaId: "1_1_town", destinationAreaId: "1_1_2" },
            { sourceAreaId: "1_1_2", destinationAreaId: "1_1_3" },
        ],
    }]

    const initialized = resolveAutoStep(acts, 0, "1_1_town", "1_1_1", 0, 8)
    assert.deepEqual(initialized, { act: 0, step: 1, matched: true })
    assert.equal(
        updateRecoveryTarget(
            { "1_1_1": { is_town_area: false }, "1_1_town": { is_town_area: true } },
            "1_1_1",
            "1_1_town",
            true,
            "1_1_1",
            "1_1_town",
            true,
        ),
        "",
    )
})

test("the first destination of the next act follows the previous act endpoint", () => {
    const acts = [
        { rows: [{ destinationAreaId: "1_1_town" }, { destinationAreaId: "1_1_11_2" }] },
        { rows: [{ destinationAreaId: "1_2_1" }, { destinationAreaId: "1_2_town" }] },
    ]
    const advanced = resolveAutoStep(acts, 1, "1_2_1", "1_1_11_2", 0, 2)
    assert.deepEqual(advanced, { act: 1, step: 1, matched: true })
})

test("the final Karui Shores destination resolves from Act 10 route data", () => {
    const acts = Array.from({ length: 10 }, () => ({ rows: [] }))
    acts[9].rows = [
        { sourceAreaId: "2_10_6", destinationAreaId: "2_10_town" },
        { sourceAreaId: "2_10_town", destinationAreaId: "2_11_endgame_town" },
        { sourceAreaId: "2_11_endgame_town", destinationAreaId: "" },
    ]
    const areas = { "2_11_endgame_town": { act: 11, is_town_area: true } }

    const reachedKaruiShores = resolveAutoStep(
        acts,
        areas["2_11_endgame_town"].act - 1,
        "2_11_endgame_town",
        "2_10_town",
        9,
        1,
        areas,
    )

    assert.deepEqual(reachedKaruiShores, { act: 9, step: 2, matched: true })
})

test("Act 2 route can return to Lioneye's Watch to complete an Act 1 quest", () => {
    const acts = [
        { rows: [{ sourceAreaId: "1_1_town", destinationAreaId: "1_1_2" }] },
        {
            rows: [
                { sourceAreaId: "1_2_9", destinationAreaId: "1_2_town" },
                { sourceAreaId: "1_2_town", destinationAreaId: "1_1_town" },
                { sourceAreaId: "1_1_town", destinationAreaId: "1_2_12" },
            ]
        },
    ]
    const areas = {
        "1_1_town": { act: 1, is_town_area: true },
        "1_2_town": { act: 2, is_town_area: true },
        "1_2_9": { act: 2 },
        "1_2_12": { act: 2 },
    }

    const returnedToActOneTown = resolveAutoStep(acts, 0, "1_1_town", "1_2_town", 1, 1, areas)
    assert.deepEqual(returnedToActOneTown, { act: 1, step: 2, matched: true })

    const continuedActTwo = resolveAutoStep(acts, 1, "1_2_12", "1_1_town", returnedToActOneTown.act, returnedToActOneTown.step, areas)
    assert.deepEqual(continuedActTwo, { act: 1, step: 3, matched: true })
})

test("entering Fellshrine from Crossroads cannot skip the expected Chamber of Sins step", () => {
    const rows = Array.from({ length: 15 }, (_, index) => ({
        sourceAreaId: `area-${index}`,
        destinationAreaId: `area-${index + 1}`,
    }))
    rows[9] = { sourceAreaId: "1_2_3", destinationAreaId: "1_2_6_1" }
    rows[10] = { sourceAreaId: "1_2_6_1", destinationAreaId: "1_2_6_2" }
    rows[11] = { sourceAreaId: "1_2_6_2", destinationAreaId: "1_2_town" }
    rows[12] = { sourceAreaId: "1_2_town", destinationAreaId: "1_2_3" }
    rows[13] = { sourceAreaId: "1_2_3", destinationAreaId: "1_2_15" }
    rows[14] = { sourceAreaId: "1_2_15", destinationAreaId: "1_2_5_1" }
    const actTwo = [{ rows }]

    const skippedAhead = resolveAutoStep(actTwo, 0, "1_2_15", "1_2_3", 0, 9)

    assert.deepEqual(skippedAhead, { act: 0, step: 9, matched: false })
})

test("starting a new campaign resets an older checkpoint cursor", () => {
    const reset = resolveAutoStep(route, 0, "1_1_1", "1_1_town", 5, 12)
    assert.deepEqual(reset, { act: 0, step: 0, matched: true })
})

test("paused in town shows the latest unfinished group sourced in that town", () => {
    const acts = [{
        rows: [
            { sourceAreaId: "1_1_1", destinationAreaId: "1_1_town" },
            { sourceAreaId: "1_1_town", destinationAreaId: "1_1_2", reminder: "buy gem" },
            { sourceAreaId: "1_1_2", destinationAreaId: "1_1_3" },
        ],
    }]

    assert.deepEqual(findPausedStep(acts, 0, "1_1_town", 0, 2), { act: 0, step: 1 })
})

test("current town actions take priority over recovery actions from the previous area", () => {
    const acts = [{
        rows: [
            { sourceAreaId: "1_1_2", destinationAreaId: "1_1_town", items: ["finish Coast"] },
            { sourceAreaId: "1_1_town", destinationAreaId: "1_1_2", items: ["buy gems"] },
            { sourceAreaId: "1_1_2", destinationAreaId: "1_1_3", items: ["enter Mud Flats"] },
        ],
    }]

    const localStep = findLocalStep(acts, 0, "1_1_town", 0, 2)
    const recoveryStep = findRecoveryStep(acts, { "1_1_2": { act: 1 } }, "1_1_2", 0, 2)

    assert.deepEqual(localStep, { act: 0, step: 1 })
    assert.deepEqual(acts[localStep.act].rows[localStep.step].items, ["buy gems"])
    assert.deepEqual(recoveryStep, { act: 0, step: 2 })
})

test("paused reminder follows the latest town visit, not a future visit", () => {
    const acts = [{
        rows: [
            { sourceAreaId: "1_1_1", destinationAreaId: "1_1_town" },
            { sourceAreaId: "1_1_town", destinationAreaId: "1_1_2", reminder: "first visit" },
            { sourceAreaId: "1_1_2", destinationAreaId: "1_1_3" },
            { sourceAreaId: "1_1_3", destinationAreaId: "1_1_town" },
            { sourceAreaId: "1_1_town", destinationAreaId: "1_1_8", reminder: "second visit" },
            { sourceAreaId: "1_1_8", destinationAreaId: "1_1_9" },
            { sourceAreaId: "1_1_9", destinationAreaId: "1_1_town" },
            { sourceAreaId: "1_1_town", destinationAreaId: "1_1_11_1", reminder: "future visit" },
        ],
    }]

    assert.deepEqual(findPausedStep(acts, 0, "1_1_town", 0, 5), { act: 0, step: 4 })
})

test("paused outside campaign preserves the existing HUD reminder", () => {
    assert.deepEqual(findPausedStep(route, -1, "HideoutLibrary", 0, 2), { act: 0, step: 2 })
})

test("checkpoint is accepted only for matching build and route identity", () => {
    const checkpoint = {
        version: 1,
        buildKey: "witch|league|None",
        routeFingerprint: "abc",
        routeMode: "leaguestart",
        bandit: "none",
        act: 0,
        step: 2,
    }
    const expected = {
        buildKey: "witch|league|None",
        routeFingerprint: "abc",
        routeMode: "leaguestart",
        bandit: "none",
    }
    assert.equal(checkpointMatches(checkpoint, expected, route), true)
    assert.equal(checkpointMatches(checkpoint, { ...expected, routeFingerprint: "updated" }, route), false)
    assert.equal(checkpointMatches(checkpoint, { ...expected, buildKey: "different-character" }, route), false)
})

test("version two checkpoint stores the directly selected route cursor", () => {
    const checkpoint = {
        version: 2,
        buildKey: "witch|league|None",
        routeFingerprint: "abc",
        routeMode: "leaguestart",
        bandit: "none",
        act: 0,
        step: 3,
    }
    const expected = {
        buildKey: "witch|league|None",
        routeFingerprint: "abc",
        routeMode: "leaguestart",
        bandit: "none",
    }
    assert.equal(checkpointMatches(checkpoint, expected, route), true)
    assert.deepEqual([checkpoint.act, checkpoint.step], [0, 3])
})

test("crash return to town retains the last non-town area as recovery target", () => {
    const areas = {
        "1_1_2": { is_town_area: false },
        "1_1_town": { is_town_area: true },
        "1_1_3": { is_town_area: false },
    }
    let target = updateRecoveryTarget(areas, "1_1_2", "1_1_town", false, "")
    assert.equal(target, "1_1_2")

    target = updateRecoveryTarget(areas, "1_1_town", "1_1_town", false, target)
    assert.equal(target, "1_1_2")

    target = updateRecoveryTarget(areas, "1_1_town", "1_1_2", false, target)
    assert.equal(target, "")
})

test("recovery target clears immediately on entering it without task completion checks", () => {
    const areas = { "1_1_2": { is_town_area: false } }

    assert.equal(updateRecoveryTarget(areas, "1_1_town", "1_1_2", false, "1_1_2"), "")
})

test("recovery target clears when route progress enters a different next area", () => {
    const areas = {
        "1_1_2": { is_town_area: false },
        "1_1_3": { is_town_area: false },
    }

    assert.equal(updateRecoveryTarget(areas, "1_1_town", "1_1_3", true, "1_1_2"), "")
})

test("entering the logout destination town from another town advances the linear route", () => {
    const acts = [{
        rows: [
            { sourceAreaId: "1_2_5_2", destinationAreaId: "1_2_town" },
            { sourceAreaId: "1_2_town", destinationAreaId: "1_2_7" },
        ],
    }]
    const areas = {
        "1_1_town": { is_town_area: true },
        "1_2_town": { is_town_area: true },
    }
    const progress = resolveAutoStep(acts, 0, "1_2_town", "1_1_town", 0, 1, areas)

    assert.deepEqual(progress, { act: 0, step: 1, matched: true })
    assert.equal(
        updateRecoveryTarget(areas, "1_1_town", "1_2_town", progress.matched, "1_2_5_2", "1_2_town", false),
        "",
    )
})

test("backtracking from Coast after entering Mud Flats points back to Mud Flats", () => {
    const areas = {
        "1_1_2": { is_town_area: false },
        "1_1_3": { is_town_area: false },
    }
    let target = updateRecoveryTarget(areas, "1_1_2", "1_1_3", true, "", "1_1_3")
    assert.equal(target, "")

    target = updateRecoveryTarget(areas, "1_1_3", "1_1_2", false, target, "1_1_3")
    assert.equal(target, "1_1_3")

    target = updateRecoveryTarget(areas, "1_1_2", "1_1_3", false, target, "1_1_3")
    assert.equal(target, "")
})

test("recovery target survives intermediate waypoint towns until target entry is confirmed", () => {
    const areas = {
        "1_1_2": { is_town_area: false, has_waypoint: false },
        "1_1_town": { is_town_area: true, has_waypoint: true },
        "1_1_3_town": { is_town_area: true, has_waypoint: true },
    }
    let target = updateRecoveryTarget(areas, "1_1_2", "1_1_town", false, "")
    target = updateRecoveryTarget(areas, "1_1_town", "1_1_3_town", false, target)
    assert.equal(target, "1_1_2")
    target = updateRecoveryTarget(areas, "1_1_3_town", "1_1_4", false, target)
    assert.equal(target, "1_1_2")
    target = updateRecoveryTarget(areas, "1_1_4", "1_1_3_town", false, target)
    assert.equal(target, "1_1_2")
    target = updateRecoveryTarget(areas, "1_1_3_town", "1_1_2", false, target)
    assert.equal(target, "")
})

test("entering the crash zone resumes its unfinished source-area step", () => {
    const acts = [{
        rows: [
            { sourceAreaId: "1_1_town", destinationAreaId: "1_1_2" },
            { sourceAreaId: "1_1_2", destinationAreaId: "1_1_3" },
            { sourceAreaId: "1_1_3", destinationAreaId: "1_1_town" },
            { sourceAreaId: "1_1_town", destinationAreaId: "1_1_8" },
        ],
    }]
    const areas = { "1_1_2": { act: 1, has_waypoint: false } }

    assert.deepEqual(resolveRecoveryStep(acts, areas, "1_1_2", "1_1_2", 0, 3), {
        act: 0,
        step: 1,
    })
})

test("paused in town shows the route block from the crash zone and its next target", () => {
    const acts = [{
        rows: [
            { sourceAreaId: "1_1_2", destinationAreaId: "1_1_3" },
            { sourceAreaId: "1_1_3", destinationAreaId: "1_1_town" },
            { sourceAreaId: "1_1_town", destinationAreaId: "1_1_4_1" },
        ],
    }]
    const areas = { "1_1_2": { act: 1, has_waypoint: false } }

    assert.deepEqual(findRecoveryStep(acts, areas, "1_1_2", 0, 2), { act: 0, step: 0 })
})

test("recovery handles the same special area reused by multiple acts", () => {
    const acts = [
        { rows: [{ sourceAreaId: "Labyrinth_Airlock" }] },
        { rows: [{ sourceAreaId: "OtherArea" }] },
        { rows: [{ sourceAreaId: "Labyrinth_Airlock" }, { sourceAreaId: "NextArea" }] },
    ]
    const areas = { Labyrinth_Airlock: { act: 3 } }

    assert.deepEqual(
        resolveRecoveryStep(acts, areas, "Labyrinth_Airlock", "Labyrinth_Airlock", 2, 1),
        { act: 2, step: 0 },
    )
})
