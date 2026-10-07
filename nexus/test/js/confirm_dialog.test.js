import { expect, test } from "bun:test"
import { confirmWithDialog } from "../../app/javascript/confirm_dialog"

// The module drives the shell <dialog> through the platform's method="dialog"
// contract, so the fake only needs showModal, the close event, and returnValue.
async function withFakeDialog(run) {
  const originalDocument = globalThis.document
  const listeners = {}
  const message = { textContent: "" }
  const confirmButton = { textContent: "" }
  const dialog = {
    returnValue: "stale-from-last-time",
    open: false,
    querySelector: (selector) => (selector === "button[value='confirm']" ? confirmButton : null),
    showModal() { this.open = true },
    addEventListener(type, listener) { listeners[type] = listener },
    closeWith(value) {
      this.open = false
      this.returnValue = value
      listeners.close()
    },
  }
  globalThis.document = {
    getElementById: (id) => (id === "turbo-confirm" ? dialog : message),
  }

  try {
    return await run({ dialog, message, confirmButton })
  } finally {
    if (originalDocument === undefined) {
      delete globalThis.document
    } else {
      globalThis.document = originalDocument
    }
  }
}

test("shows the message, repeats the submitter's verb, and resolves true on confirm", async () => {
  await withFakeDialog(async ({ dialog, message, confirmButton }) => {
    const submitter = { value: "", textContent: "  Revoke  " }
    const answer = confirmWithDialog("Revoke helper? It stops working.", null, submitter)

    expect(dialog.open).toBe(true)
    expect(message.textContent).toBe("Revoke helper? It stops working.")
    expect(confirmButton.textContent).toBe("Revoke")

    dialog.closeWith("confirm")
    expect(await answer).toBe(true)
  })
})

test("cancel and Escape resolve false, including a stale returnValue from an earlier confirm", async () => {
  await withFakeDialog(async ({ dialog }) => {
    const cancelled = confirmWithDialog("Sure?", null, null)
    dialog.closeWith("cancel")
    expect(await cancelled).toBe(false)

    // Escape closes without a submitter: returnValue stays as reset ("").
    const escaped = confirmWithDialog("Sure?", null, null)
    expect(dialog.returnValue).toBe("")
    dialog.closeWith(dialog.returnValue)
    expect(await escaped).toBe(false)
  })
})

test("an input submitter carries its label through value; no submitter falls back to Confirm", async () => {
  await withFakeDialog(async ({ dialog, confirmButton }) => {
    const viaInput = confirmWithDialog("Take over?", null, { value: "Take over", textContent: "" })
    expect(confirmButton.textContent).toBe("Take over")
    dialog.closeWith("cancel")
    await viaInput

    const bare = confirmWithDialog("Sure?", null, null)
    expect(confirmButton.textContent).toBe("Confirm")
    dialog.closeWith("cancel")
    await bare
  })
})
