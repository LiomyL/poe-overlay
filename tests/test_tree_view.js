const assert = require("node:assert/strict")
const test = require("node:test")
const { compareTrees, connectionState } = require("../tree_view.js")

test("tree comparison classifies shared, added, and removed nodes", () => {
    const delta = compareTrees(
        { nodes: ["shared", "new"], masteries: {} },
        { nodes: ["shared", "removed"], masteries: {} },
    )

    assert.deepEqual(delta, {
        active: ["shared"],
        added: ["new"],
        removed: ["removed"],
    })
})

test("changing a mastery effect marks its node as newly allocated", () => {
    const delta = compareTrees(
        { nodes: ["mastery"], masteries: { mastery: "new-effect" } },
        { nodes: ["mastery"], masteries: { mastery: "old-effect" } },
    )

    assert.deepEqual(delta, { active: [], added: ["mastery"], removed: [] })
})

test("new connections do not make unallocated neighboring nodes look selected", () => {
    assert.equal(connectionState("added", "base"), "base")
    assert.equal(connectionState("base", "added"), "base")
    assert.equal(connectionState("added", "added"), "added")
    assert.equal(connectionState("added", "active"), "added")
})

test("removed connections only highlight removed or shared nodes", () => {
    assert.equal(connectionState("removed", "base"), "base")
    assert.equal(connectionState("base", "removed"), "base")
    assert.equal(connectionState("removed", "removed"), "removed")
    assert.equal(connectionState("removed", "active"), "removed")
})
