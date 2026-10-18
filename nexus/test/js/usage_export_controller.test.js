import { expect, test } from "bun:test"
import UsageExportController from "../../app/javascript/controllers/usage_export_controller"

test("native date edits preserve an untouched microsecond boundary and restore it when the edit is undone", () => {
  const exact = "2026-10-18T04:15:30.123456Z"
  const input = { value: "2026-10-18T04:15:30", dataset: {
    boundary: "from", original: "2026-10-18T04:15:30", exact,
  } }
  const hidden = { value: exact }
  const controller = Object.assign(Object.create(UsageExportController.prototype), { datetimeTargets: [input] })
  Object.defineProperty(controller, "element", { value: { elements: { namedItem: () => hidden } } })

  controller.sync()
  expect(hidden.value).toBe(exact)
  input.value = "2026-10-17T09:00"
  controller.sync()
  expect(hidden.value).toBe("2026-10-17T09:00Z")
  input.value = "2026-10-18T04:15:30"
  controller.sync()
  expect(hidden.value).toBe(exact)
})
