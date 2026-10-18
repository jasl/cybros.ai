import { afterEach, beforeEach, expect, mock, test } from "bun:test"
import WorkRefreshController from "../../app/javascript/controllers/work_refresh_controller"

const originalDocument = globalThis.document
const originalWindow = globalThis.window
let visits

mock.module("@hotwired/turbo-rails", () => ({
  cable: { subscribeTo: async () => ({ unsubscribe() {} }) },
  Turbo: { visit(url, options) {
    visits.push({ url, options })
    document.dispatchEvent(new Event("turbo:visit"))
  } },
}))

beforeEach(() => {
  visits = []
  globalThis.document = new EventTarget()
  globalThis.window = { location: { href: "http://nexus.test/runs/example/tasks/question" }, scrollX: 0, scrollY: 20, scrollTo() {} }
})

afterEach(() => {
  globalThis.document = originalDocument
  globalThis.window = originalWindow
})

function controller() {
  return Object.assign(Object.create(WorkRefreshController.prototype), {
    active: true, dirty: false, hasStatusTarget: true,
    statusTarget: { textContent: "", dataset: { pending: "Unsent answer kept", live: "Connected" } },
  })
}

async function answerPage() {
  const subject = controller()
  const answer = { value: "", defaultValue: "" }
  const element = Object.assign(new EventTarget(), { querySelectorAll: () => [answer], closest: () => null })
  Object.defineProperty(subject, "element", { value: element })
  await subject.connect()
  return { subject, answer, element }
}

function responseRender(render) {
  const event = new CustomEvent("turbo:before-render", { detail: { render } })
  document.dispatchEvent(event)
  return event.detail.render
}

test("incoming events preserve an unsent answer instead of replacing the page", () => {
  const subject = controller()
  let refreshed = false
  subject.refresh = () => { refreshed = true }
  Object.defineProperty(subject, "element", { value: { querySelectorAll: () => [{ value: "draft", defaultValue: "" }] } })
  subject.changed()
  subject.received()
  expect(subject.statusTarget.textContent).toBe("Unsent answer kept")
  expect(refreshed).toBe(false)
  expect(subject.timer).toBeUndefined()
})

test("bursts schedule one bounded refresh and disconnected controllers do not refresh", () => {
  const original = globalThis.setTimeout
  const timers = []
  globalThis.setTimeout = (callback, delay) => { timers.push({ callback, delay }); return timers.length }
  try {
    const subject = controller()
    let refreshed = 0
    subject.refresh = () => { refreshed += 1 }
    subject.received()
    subject.received()
    expect(timers).toHaveLength(1)
    expect(timers[0].delay).toBe(500)
    timers[0].callback()
    expect(refreshed).toBe(1)
    subject.active = false
    subject.received()
    expect(timers).toHaveLength(1)
  } finally {
    globalThis.setTimeout = original
  }
})

test("disconnect cancels the subscription and timer", () => {
  const original = globalThis.clearTimeout
  let cleared
  let unsubscribed = false
  globalThis.clearTimeout = value => { cleared = value }
  try {
    const subject = controller()
    subject.timer = 42
    Object.defineProperty(subject, "element", { value: { removeEventListener() {} } })
    subject.subscription = { unsubscribe() { unsubscribed = true } }
    subject.disconnect()
    expect(subject.active).toBe(false)
    expect(cleared).toBe(42)
    expect(unsubscribed).toBe(true)
  } finally {
    globalThis.clearTimeout = original
  }
})

test("clearing the draft releases the pending refresh", () => {
  const subject = controller()
  subject.dirty = true
  let received = false
  subject.received = () => { received = true }
  Object.defineProperty(subject, "element", { value: { querySelectorAll: () => [{ value: "", defaultValue: "" }] } })
  subject.changed()
  expect(subject.dirty).toBe(false)
  expect(received).toBe(true)
})

test("navigation cancels queued refreshes and suppresses new refreshes until its response loads", async () => {
  const originalSetTimeout = globalThis.setTimeout
  const originalClearTimeout = globalThis.clearTimeout
  const timers = new Map()
  let nextTimer = 0
  globalThis.setTimeout = callback => { timers.set(++nextTimer, callback); return nextTimer }
  globalThis.clearTimeout = timer => timers.delete(timer)
  try {
    for (const navigation of ["turbo:visit", "turbo:submit-start"]) {
      const { subject } = await answerPage()
      try {
        subject.received()
        expect(timers.size).toBe(1)
        document.dispatchEvent(new Event(navigation))
        expect(timers.size).toBe(0)
        subject.received()
        expect(timers.size).toBe(0)
        await subject.refresh()
        expect(visits).toHaveLength(0)
        document.dispatchEvent(new Event("turbo:load"))
        subject.received()
        expect(timers.size).toBe(1)
      } finally {
        subject.disconnect()
      }
    }
  } finally {
    globalThis.setTimeout = originalSetTimeout
    globalThis.clearTimeout = originalClearTimeout
  }
})

test("navigation that starts while Turbo is importing prevents the old page refresh", async () => {
  for (const navigation of ["turbo:visit", "turbo:submit-start"]) {
    const { subject } = await answerPage()
    try {
      const refresh = subject.refresh()
      document.dispatchEvent(new Event(navigation))
      await refresh
      expect(visits).toHaveLength(0)
    } finally {
      subject.disconnect()
    }
  }
})

test("an unsuccessful submission permits future refreshes without a load event", async () => {
  const { subject } = await answerPage()
  try {
    document.dispatchEvent(new Event("turbo:submit-start"))
    document.dispatchEvent(new CustomEvent("turbo:submit-end", { detail: { success: false } }))
    await subject.refresh()
    expect(visits).toHaveLength(1)
  } finally {
    subject.disconnect()
  }
})

test("a successful submission waits for its redirected response before permitting refreshes", async () => {
  const { subject } = await answerPage()
  try {
    document.dispatchEvent(new Event("turbo:submit-start"))
    document.dispatchEvent(new CustomEvent("turbo:submit-end", { detail: { success: true } }))
    await subject.refresh()
    expect(visits).toHaveLength(0)
    document.dispatchEvent(new Event("turbo:visit"))
    await subject.refresh()
    expect(visits).toHaveLength(0)
    document.dispatchEvent(new Event("turbo:load"))
    await subject.refresh()
    expect(visits).toHaveLength(1)
  } finally {
    subject.disconnect()
  }
})

test("a draft entered after the refresh request survives its response render", async () => {
  const { subject, answer, element } = await answerPage()
  try {
    await subject.refresh()
    expect(visits).toEqual([{ url: window.location.href, options: { action: "replace", refresh: { scroll: "preserve" } } }])
    answer.value = "Answer typed while the request is pending"
    element.dispatchEvent(new Event("input"))
    responseRender(() => { answer.value = "" })()
    document.dispatchEvent(new Event("turbo:load"))
    expect(answer.value).toBe("Answer typed while the request is pending")
    expect(subject.statusTarget.textContent).toBe("Unsent answer kept")
  } finally {
    subject.disconnect()
  }
})

test("the refresh checks the draft at body replacement and clearing it allows replacement", async () => {
  const { subject, answer, element } = await answerPage()
  const original = globalThis.setTimeout
  let scheduled
  try {
    await subject.refresh()
    let rendered = false
    const render = responseRender(() => { rendered = true })
    answer.value = "A late draft"
    element.dispatchEvent(new Event("input"))
    render()
    expect(rendered).toBe(false)
    document.dispatchEvent(new Event("turbo:load"))
    globalThis.setTimeout = callback => { scheduled = callback; return 1 }
    const refresh = subject.refresh.bind(subject)
    let nextRequest
    subject.refresh = () => { nextRequest = refresh(); return nextRequest }
    answer.value = ""
    element.dispatchEvent(new Event("input"))
    scheduled()
    await nextRequest
    expect(visits).toHaveLength(2)
    responseRender(() => { rendered = true })()
    expect(rendered).toBe(true)
  } finally {
    globalThis.setTimeout = original
    subject.disconnect()
  }
})

test("ordinary navigation and answer submission retain their own response rendering", async () => {
  for (const navigation of ["turbo:visit", "turbo:submit-start"]) {
    const { subject, answer, element } = await answerPage()
    try {
      await subject.refresh()
      answer.value = "An answer being submitted or left behind"
      element.dispatchEvent(new Event("input"))
      let scrolled = false
      window.scrollTo = () => { scrolled = true }
      document.dispatchEvent(new Event(navigation))
      let rendered = false
      responseRender(() => { rendered = true })()
      document.dispatchEvent(new Event("turbo:load"))
      expect(rendered).toBe(true)
      expect(scrolled).toBe(false)
    } finally {
      subject.disconnect()
    }
  }
})

test("disconnect removes the pending render protection", async () => {
  const { subject, answer, element } = await answerPage()
  await subject.refresh()
  answer.value = "An old page's draft"
  element.dispatchEvent(new Event("input"))
  subject.disconnect()
  let rendered = false
  responseRender(() => { rendered = true })()
  expect(rendered).toBe(true)
})
