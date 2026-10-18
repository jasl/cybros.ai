import { expect, test } from "bun:test"
import { file, YAML } from "bun"
import DeploymentController, { readProgress } from "../../app/javascript/controllers/deployment_controller"

const { en: copy } = YAML.parse(await file(new URL("../../config/locales/console.en.yml", import.meta.url)).text())

const operationId = "019a0000-0000-7000-8000-000000000001"
const key = "019a0000-0000-7000-8000-000000000002"
const candidate = { release: "2610080750", images: [{ name: "kernel", reference: "example/kernel@sha256:abc" }] }
const receipt = {
  id: operationId, idempotency_key: key, backup: true, target: candidate, phase: "preparing", status: "running",
  updated_at: "2026-10-08T09:30:00Z", error: null, recovery: null, log_cursor: "tail", database_backup: null,
}

function response(body, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } })
}

function streamResponse(events) {
  return new Response(events.map(([name, payload]) => `event: ${name}\ndata: ${JSON.stringify(payload)}\n\n`).join(""),
    { headers: { "Content-Type": "text/event-stream" } })
}

async function withController(run) {
  const originals = { window: globalThis.window, fetch: globalThis.fetch, setTimeout: globalThis.setTimeout, clearTimeout: globalThis.clearTimeout }
  const requests = []
  const timers = []
  const stored = new Map()
  const replacements = []
  const navigations = []
  globalThis.window = {
    location: { origin: "https://nexus.example", assign: url => navigations.push(url) },
    history: { state: { turbo: "state" }, replaceState: (...args) => replacements.push(args) },
    sessionStorage: { getItem: name => stored.get(name), setItem: (name, value) => stored.set(name, value),
      removeItem: name => stored.delete(name) },
  }
  globalThis.setTimeout = (callback, delay) => { timers.push({ callback, delay }); return timers.length }
  globalThis.clearTimeout = () => {}
  const controller = Object.assign(Object.create(DeploymentController.prototype), {
    abort: new AbortController(), observer: new AbortController(), failures: 0, cursor: null, logParts: [],
    pending: null, operation: null, statusUrlValue: "/api/v1/admin/deployment",
    upgradesUrlValue: "/api/v1/admin/deployment/upgrades", upgradePagesUrlValue: "/admin/deployment/upgrades",
    pageUrlValue: "/admin/deployment", phaseLabelsValue: { preparing: "Preparing images" },
    statusLabelsValue: { running: "In progress", succeeded: "Succeeded" },
    messagesValue: copy.deployment.messages, localeValue: "en",
    hasCheckButtonTarget: true, hasUpgradeButtonTarget: true, hasBackupChoiceTarget: true,
    hasBackupFieldTarget: true, upgradeReadyValue: true, checkedBackupValue: true,
  })
  for (const target of DeploymentController.targets) controller[`${target}Target`] = { hidden: true, textContent: "", disabled: false }
  controller.backupChoiceTarget.checked = true
  const mockFetch = handler => {
    globalThis.fetch = async (url, options) => {
      requests.push({ url: String(url), ...options })
      return handler(url, options)
    }
  }
  try {
    await run({ controller, requests, timers, stored, replacements, navigations, mockFetch })
  } finally {
    controller.disconnect()
    for (const [name, value] of Object.entries(originals)) {
      if (value === undefined) delete globalThis[name]
      else globalThis[name] = value
    }
  }
}

test("a lost upgrade response recovers the accepted receipt with GET and never repeats POST", async () => {
  await withController(async ({ controller, requests, mockFetch }) => {
    controller.pending = { idempotency_key: key, candidate, backup: false }
    const followed = []
    controller.follow = value => followed.push(value)
    mockFetch((_url, options) => {
      if (options.method === "POST") throw new TypeError("connection closed")
      return response({ deployment: { active_operation: receipt, last_operation: null } })
    })

    await controller.submitPending()

    expect(requests.map(request => request.method || "GET")).toEqual(["POST", "GET"])
    expect(JSON.parse(requests[0].body)).toEqual({ idempotency_key: key, candidate, backup: false })
    expect(followed).toEqual([receipt])
    expect(controller.pending).toBeNull()
  })
})

test("an unconfirmed request restores its frozen backup choice and exact envelope for explicit retry", async () => {
  await withController(async ({ controller, requests, stored, mockFetch }) => {
    controller.pending = { idempotency_key: key, candidate, backup: false }
    controller.savePending()
    mockFetch((_url, options) => options.method === "POST" ?
      response({}, 503) : response({ deployment: { active_operation: null, last_operation: null } }))

    await controller.submitPending()
    expect(requests.filter(request => request.method === "POST")).toHaveLength(1)
    expect(controller.pending).toEqual({ idempotency_key: key, candidate, backup: false })
    expect(controller.pendingActionsTarget.hidden).toBe(false)
    expect(controller.upgradeButtonTarget.disabled).toBe(true)

    controller.pending = null
    controller.connect()
    expect(controller.pending).toEqual(JSON.parse(stored.get("nexus.deployment.pending")))
    expect(controller.backupChoiceTarget.checked).toBe(false)
    expect(controller.backupChoiceTarget.disabled).toBe(true)
    controller.backupChoiceTarget.checked = true
    await controller.retry()
    const posts = requests.filter(request => request.method === "POST")
    expect(posts).toHaveLength(2)
    expect(posts[1].body).toBe(posts[0].body)
  })
})

test("release checks send the current backup choice and changes require a matching preflight", async () => {
  await withController(async ({ controller, requests, navigations, mockFetch }) => {
    mockFetch(() => response({ deployment: {} }))
    controller.backupChoiceTarget.checked = false
    controller.backupChanged()
    expect(controller.upgradeButtonTarget.disabled).toBe(true)
    expect(controller.backupCheckNoticeTarget.hidden).toBe(false)
    expect(controller.backupFieldTarget.value).toBe("false")
    await controller.upgrade({ preventDefault() {} })
    expect(requests).toHaveLength(0)

    await controller.check({ preventDefault() {}, currentTarget: { action: "/admin/deployment/release_check" } })
    expect(JSON.parse(requests[0].body)).toEqual({ release_check: { backup: false } })
    expect(navigations).toEqual(["/admin/deployment"])

    controller.checkedBackupValue = false
    controller.backupChanged()
    expect(controller.upgradeButtonTarget.disabled).toBe(false)
    expect(controller.backupCheckNoticeTarget.hidden).toBe(true)
  })
})

test("a restarting Nexus retries only progress reads and resumes from the last cursor", async () => {
  await withController(async ({ controller, requests, timers, mockFetch }) => {
    controller.operation = receipt
    mockFetch(() => requests.length === 1 ?
      streamResponse([["deployment.progress.v1", { operation: receipt, entries: [{ cursor: "half", text: "Preparing images\n" }], next_cursor: "half" }]]) :
      response({}, 503))

    await controller.observe()
    expect(controller.cursor).toBe("half")
    expect(controller.logTarget.textContent).toBe("Preparing images\n")
    await timers[0].callback()

    expect(requests.every(request => !request.method || request.method === "GET")).toBe(true)
    expect(requests[1].url).toContain("cursor=half")
    expect(controller.connectionTarget.textContent).toContain("Reconnecting")
    expect(timers.at(-1).delay).toBe(2000)
  })
})

test("a terminal receipt continues reading until its opaque log tail is delivered", async () => {
  await withController(async ({ controller, timers, mockFetch }) => {
    controller.operation = receipt
    const completed = { ...receipt, phase: "completed", status: "succeeded" }
    mockFetch(() => streamResponse([
      ["deployment.progress.v1", { operation: completed, entries: [{ cursor: "half", text: "First\n" }], next_cursor: "half" }],
      ["deployment.progress.v1", { operation: completed, entries: [{ cursor: "tail", text: "Complete\n" }], next_cursor: "tail" }],
    ]))

    await controller.observe()

    expect(controller.cursor).toBe("tail")
    expect(controller.logTarget.textContent).toBe("First\nComplete\n")
    expect(controller.reloadTarget.hidden).toBe(false)
    expect(controller.connectionTarget.textContent).toBe("Saved upgrade result.")
    expect(timers).toHaveLength(0)
  })
})

test("loading a saved terminal receipt preserves the page URL and available release controls", async () => {
  await withController(async ({ controller, replacements }) => {
    controller.receiptValue = { ...receipt, phase: "completed", status: "succeeded" }
    controller.observe = async () => {}

    controller.connect()

    expect(controller.checkButtonTarget.disabled).toBe(false)
    expect(controller.upgradeButtonTarget.disabled).toBe(false)
    expect(replacements).toHaveLength(0)

    controller.setBusy(true)
    controller.updateReceipt(controller.receiptValue)
    expect(controller.checkButtonTarget.disabled).toBe(true)
    expect(controller.upgradeButtonTarget.disabled).toBe(true)
  })
})

test("a failed release check never enables an upgrade blocked by its preflight report", async () => {
  await withController(async ({ controller, mockFetch }) => {
    controller.upgradeReadyValue = false
    mockFetch(() => response({ error: { message: "The updater is unavailable." } }, 503))

    await controller.check({ preventDefault() {}, currentTarget: { action: "/admin/deployment/release_check" } })

    expect(controller.checkButtonTarget.disabled).toBe(false)
    expect(controller.upgradeButtonTarget.disabled).toBe(true)
    expect(controller.noticeTarget.textContent).toBe("The updater is unavailable.")
  })
})

test("a newly blocked acceptance reloads its report without retrying the upgrade", async () => {
  await withController(async ({ controller, requests, navigations, mockFetch }) => {
    controller.pending = { idempotency_key: key, candidate, backup: false }
    mockFetch(() => response({ error: { code: "preflight_failed", message: "The installation needs more space." } }, 409))

    await controller.submitPending()

    expect(requests.map(request => request.method)).toEqual(["POST"])
    expect(controller.pending).toBeNull()
    expect(controller.upgradeButtonTarget.disabled).toBe(true)
    expect(navigations).toEqual(["/admin/deployment"])
  })
})

test("progress displays only backup metadata and distinguishes an expired backup", async () => {
  for (const available of [true, false]) {
    await withController(async ({ controller, mockFetch }) => {
      controller.operation = receipt
      const completed = { ...receipt, status: "succeeded", phase: "completed", database_backup: {
        created_at: "2026-10-08T09:30:02Z", size_bytes: 1048576, available,
      } }
      mockFetch(() => streamResponse([
        ["deployment.progress.v1", { operation: completed, entries: [], next_cursor: "tail" }],
      ]))

      await controller.observe()

      expect(controller.databaseBackupTarget.hidden).toBe(false)
      expect(controller.backupCreatedAtTarget.textContent).toBe("2026-10-08T09:30:02Z")
      expect(controller.backupSizeTarget.textContent).toBe("1,048,576 bytes")
      expect(controller.backupAvailabilityTarget.textContent).toBe(available ? "Available on the installation host" : "No longer retained")
    })
  }
})

test("a skipped backup is visible without retained backup metadata or empty detail fields", async () => {
  await withController(async ({ controller }) => {
    controller.updateReceipt({ ...receipt, backup: false, status: "succeeded", phase: "completed" })

    expect(controller.databaseBackupTarget.hidden).toBe(false)
    expect(controller.backupAvailabilityTarget.textContent).toBe("Skipped for this upgrade")
    expect(controller.backupDetailsTarget.hidden).toBe(true)
    expect(controller.backupHelpTarget.hidden).toBe(true)
  })
})

test("an interrupted receipt stops at an empty log window even when its persisted tail is missing or stale", async () => {
  for (const logCursor of [null, "earlier"]) {
    await withController(async ({ controller, timers, mockFetch }) => {
      controller.operation = receipt
      const interrupted = { ...receipt, status: "interrupted", log_cursor: logCursor }
      mockFetch(() => streamResponse([
        ["deployment.progress.v1", { operation: interrupted, entries: [], next_cursor: "tail" }],
      ]))

      await controller.observe()

      expect(controller.connectionTarget.textContent).toBe("Saved upgrade result.")
      expect(controller.cursor).toBe("tail")
      expect(timers).toHaveLength(0)
    })
  }
})

test("a revoked administrator loses observation without another connection attempt", async () => {
  await withController(async ({ controller, timers, mockFetch }) => {
    controller.operation = receipt
    mockFetch(() => streamResponse([["deployment.error.v1",
      { code: "administrator_required", message: "Sign in again." }]]))

    await controller.observe()

    expect(controller.connectionTarget.textContent).toContain("Administrator access ended")
    expect(controller.reconnectTarget.hidden).toBe(true)
    expect(controller.upgradeButtonTarget.disabled).toBe(true)
    expect(timers).toHaveLength(0)
  })
})

test("backoff is capped and eventually leaves reconnection to the person", async () => {
  await withController(async ({ controller, timers }) => {
    for (let attempt = 0; attempt < 20; attempt += 1) controller.schedule(() => {}, true)

    expect(Math.max(...timers.map(timer => timer.delay))).toBe(15000)
    expect(timers).toHaveLength(19)
    expect(controller.reconnectTarget.hidden).toBe(false)
    expect(controller.connectionTarget.textContent).toContain("Automatic reconnection paused")
  })
})

test("progress framing preserves split UTF-8 and renders log text as text", async () => {
  const payload = { operation: receipt, entries: [{ cursor: "tail", text: "更新 <img onerror=alert(1)>\n" }], next_cursor: "tail" }
  const bytes = new TextEncoder().encode(`event: deployment.progress.v1\r\ndata: ${JSON.stringify(payload)}\r\n\r\n`)
  const stream = new ReadableStream({
    start(output) {
      for (let index = 0; index < bytes.length; index += 7) output.enqueue(bytes.slice(index, index + 7))
      output.close()
    },
  })
  const events = []
  await readProgress(new Response(stream), (name, value) => events.push([name, value]))
  expect(events).toEqual([["deployment.progress.v1", payload]])

  await withController(async ({ controller }) => {
    controller.appendLog(payload.entries)
    expect(controller.logTarget.textContent).toBe(payload.entries[0].text)
    expect(controller.logTarget.innerHTML).toBeUndefined()
  })
})
