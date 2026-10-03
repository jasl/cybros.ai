import { expect, test } from "bun:test"
import SetupSecretController from "../../app/javascript/controllers/setup_secret_controller"

function withSetupPage(url, run, { hasSecretTarget = true, value = "" } = {}) {
  const originalWindow = globalThis.window
  const replacements = []
  const state = { turbo: { restorationIdentifier: "existing-visit" } }
  globalThis.window = {
    location: new URL(url),
    history: { state, replaceState: (...args) => replacements.push(args) },
  }
  const controller = Object.assign(Object.create(SetupSecretController.prototype), {
    hasSecretTarget,
    secretTarget: { value },
  })

  try {
    run({ controller, replacements, state })
  } finally {
    if (originalWindow === undefined) delete globalThis.window
    else globalThis.window = originalWindow
  }
}

test("the installation fragment fills the password field and leaves a clean URL with its history state", () => {
  withSetupPage("https://nexus.example/setup?locale=en#setup_secret=installation%20secret", ({ controller, replacements, state }) => {
    controller.connect()

    expect(replacements).toEqual([[state, "", "/setup?locale=en"]])
    expect(controller.secretTarget.value).toBe("installation secret")
  })
})

test("ordinary fragment navigation does not replace a manually entered setup secret", () => {
  withSetupPage("https://nexus.example/setup#main", ({ controller, replacements }) => {
    controller.connect()

    expect(replacements).toEqual([])
    expect(controller.secretTarget.value).toBe("manual secret")
  }, { value: "manual secret" })
})

test("the installation fragment is removed even when this deployment needs no setup secret", () => {
  withSetupPage("https://nexus.example/setup#setup_secret=unused", ({ controller, replacements, state }) => {
    controller.connect()

    expect(replacements).toEqual([[state, "", "/setup"]])
    expect(controller.secretTarget.value).toBe("")
  }, { hasSecretTarget: false })
})

test("a failed submission keeps the setup secret for correction and success clears it", () => {
  withSetupPage("https://nexus.example/setup", ({ controller }) => {
    controller.submitted({ detail: { success: false } })
    expect(controller.secretTarget.value).toBe("manual secret")

    controller.submitted({ detail: { success: true } })
    expect(controller.secretTarget.value).toBe("")
  }, { value: "manual secret" })
})
