// Replaces Turbo's native window.confirm for every data-turbo-confirm
// submission (wired in application.js). The shell <dialog>
// (layouts/shared/_confirm_dialog) closes through method="dialog" buttons,
// so the chosen branch arrives as returnValue: "confirm" resolves true and
// anything else — Cancel, Escape, the backdrop — resolves false.
export function confirmWithDialog(message, _form, submitter) {
  const dialog = document.getElementById("turbo-confirm")
  document.getElementById("turbo-confirm-message").textContent = message
  dialog.querySelector("button[value='confirm']").textContent = submitterLabel(submitter, dialog.dataset.confirmLabel)

  dialog.returnValue = ""
  dialog.showModal()
  return new Promise((resolve) => {
    dialog.addEventListener("close", () => resolve(dialog.returnValue === "confirm"), { once: true })
  })
}

// The confirm branch repeats the verb the user just pressed: button_to
// renders a <button> (textContent), form.submit an <input> (value).
function submitterLabel(submitter, fallback) {
  const label = submitter && (submitter.value || submitter.textContent).trim()
  return label || fallback
}
