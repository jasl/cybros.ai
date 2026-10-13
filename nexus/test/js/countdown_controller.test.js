import { expect, test } from "bun:test"
import CountdownController from "../../app/javascript/controllers/ui/countdown_controller"

test("resend countdown interpolates the translated sentence and restores its translated action", () => {
  const controller = Object.assign(Object.create(CountdownController.prototype), {
    pendingLabelValue: "Dans %{seconds}s, renvoyer",
    buttonTarget: { textContent: "", disabled: true, dataset: { countdownLabel: "Renvoyer" } },
    deadline: Date.now() + 2500,
  })

  controller.tick()
  expect(controller.buttonTarget.textContent).toBe("Dans 3s, renvoyer")
  expect(controller.buttonTarget.disabled).toBe(true)

  controller.deadline = Date.now() - 1
  controller.tick()
  expect(controller.buttonTarget.textContent).toBe("Renvoyer")
  expect(controller.buttonTarget.disabled).toBe(false)
})
