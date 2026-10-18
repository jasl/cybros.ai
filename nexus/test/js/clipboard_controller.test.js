import { expect, test } from "bun:test"
import ClipboardController from "../../app/javascript/controllers/ui/clipboard_controller"

test("copy falls back to selecting the invitation link outside secure contexts", () => {
  const originalNavigator = globalThis.navigator
  const originalDocument = globalThis.document
  let selected = false
  let copied = false
  const controller = Object.assign(Object.create(ClipboardController.prototype), {
    sourceTarget: {
      value: "http://nexus.example/join?token=secret",
      select: () => { selected = true },
    },
    buttonTarget: { textContent: "Copy" },
    showCopied: () => { copied = true },
  })

  Object.defineProperty(globalThis, "navigator", { configurable: true, value: {} })
  globalThis.document = { execCommand: (command) => command === "copy" }

  try {
    ClipboardController.prototype.copy.call(controller)
  } finally {
    if (originalNavigator === undefined) {
      delete globalThis.navigator
    } else {
      Object.defineProperty(globalThis, "navigator", { configurable: true, value: originalNavigator })
    }

    if (originalDocument === undefined) {
      delete globalThis.document
    } else {
      globalThis.document = originalDocument
    }
  }

  expect(selected).toBe(true)
  expect(copied).toBe(true)
})

test("copy feedback uses the translated label and restores the original button label", () => {
  const originalTimeout = globalThis.setTimeout
  let restore
  const controller = Object.assign(Object.create(ClipboardController.prototype), {
    copiedValue: "Copié",
    buttonTarget: { textContent: "Copier" },
  })
  globalThis.setTimeout = callback => { restore = callback }

  try {
    controller.connect()
    controller.showCopied()
    expect(controller.buttonTarget.textContent).toBe("Copié")
    restore()
    expect(controller.buttonTarget.textContent).toBe("Copier")
  } finally {
    globalThis.setTimeout = originalTimeout
  }
})

test("copy uses the exact code text including whitespace without copying markup or button labels", async () => {
  const originalNavigator = globalThis.navigator
  const source = "<script>still text</script>\n  indented & exact\n"
  let copiedText
  let feedback = false
  const controller = Object.assign(Object.create(ClipboardController.prototype), {
    sourceTarget: { textContent: source },
    showCopied: () => { feedback = true },
  })
  Object.defineProperty(globalThis, "navigator", { configurable: true, value: {
    clipboard: { writeText: async text => { copiedText = text } },
  } })
  try {
    controller.copy()
    await Promise.resolve()
    expect(copiedText).toBe(source)
    expect(feedback).toBe(true)
  } finally {
    Object.defineProperty(globalThis, "navigator", { configurable: true, value: originalNavigator })
  }
})

test("denied clipboard permission falls back to selecting only the code source", async () => {
  const originals = { navigator: globalThis.navigator, document: globalThis.document, window: globalThis.window }
  const source = { textContent: "exact code\n" }
  let selected
  let addedRange
  let copied = false
  const range = { selectNodeContents: node => { selected = node } }
  const controller = Object.assign(Object.create(ClipboardController.prototype), {
    sourceTarget: source,
    showCopied: () => { copied = true },
  })
  Object.defineProperty(globalThis, "navigator", { configurable: true, value: {
    clipboard: { writeText: async () => { throw new Error("denied") } },
  } })
  globalThis.document = { createRange: () => range, execCommand: command => command === "copy" }
  globalThis.window = { getSelection: () => ({ removeAllRanges: () => {}, addRange: value => { addedRange = value } }) }
  try {
    controller.copy()
    await Promise.resolve()
    expect(selected).toBe(source)
    expect(addedRange).toBe(range)
    expect(copied).toBe(true)
  } finally {
    for (const [key, value] of Object.entries(originals)) {
      if (value === undefined) delete globalThis[key]
      else Object.defineProperty(globalThis, key, { configurable: true, writable: true, value })
    }
  }
})
