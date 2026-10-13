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
