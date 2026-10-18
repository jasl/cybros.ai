import { Controller } from "@hotwired/stimulus"

// Events are invalidation hints. The current URL remains the read authority,
// including its selected task, cursor and filters. No command is replayed.
export default class extends Controller {
  static targets = ["status"]
  static values = { channel: String, workspaceId: String, resourceId: String }

  async connect() {
    this.active = true
    this.dirty = false
    this.navigationPending = false
    this.connectedOnce = false
    this.listenForInput = () => this.changed()
    this.guardRender = event => this.beforeRender(event)
    this.cancelRefresh = () => {
      clearTimeout(this.timer)
      this.timer = null
      this.refreshing = false
      this.navigationPending = true
    }
    this.finishNavigation = () => {
      this.refreshing = false
      this.navigationPending = false
    }
    this.finishSubmission = event => {
      // Failed HTML submissions render without turbo:load; successful ones redirect.
      if (event.detail.success === false) this.finishNavigation()
    }
    this.element.addEventListener("input", this.listenForInput)
    document.addEventListener("turbo:before-render", this.guardRender)
    document.addEventListener("turbo:visit", this.cancelRefresh)
    document.addEventListener("turbo:submit-start", this.cancelRefresh)
    document.addEventListener("turbo:submit-end", this.finishSubmission)
    document.addEventListener("turbo:load", this.finishNavigation)
    const resourceKey = this.channelValue === "AgentAPI::V1::RunEventsChannel" ? "run_id" : "conversation_id"
    const { cable } = await import("@hotwired/turbo-rails")
    if (!this.active) return
    const subscription = await cable.subscribeTo({ channel: this.channelValue,
      workspace_id: this.workspaceIdValue, [resourceKey]: this.resourceIdValue, items: "events" }, {
      connected: () => {
        this.status("live")
        if (this.connectedOnce) this.received()
        this.connectedOnce = true
      },
      disconnected: () => this.status("disconnected"),
      rejected: () => this.status("disconnected"),
      received: () => this.received(),
    })
    if (this.active) this.subscription = subscription
    else subscription.unsubscribe()
  }

  disconnect() {
    this.active = false
    clearTimeout(this.timer)
    this.subscription?.unsubscribe()
    this.element.removeEventListener("input", this.listenForInput)
    document.removeEventListener("turbo:before-render", this.guardRender)
    document.removeEventListener("turbo:visit", this.cancelRefresh)
    document.removeEventListener("turbo:submit-start", this.cancelRefresh)
    document.removeEventListener("turbo:submit-end", this.finishSubmission)
    document.removeEventListener("turbo:load", this.finishNavigation)
  }

  changed() {
    this.dirty = Array.from(this.element.querySelectorAll("textarea, input:not([type=hidden])")).some(field =>
      ["checkbox", "radio"].includes(field.type) ? field.checked !== field.defaultChecked : field.value !== field.defaultValue)
    if (!this.dirty) this.received()
  }

  received() {
    if (!this.active || this.navigationPending) return
    if (this.dirty) {
      this.status("pending")
      return
    }
    // Sustained deltas still produce a bounded refresh every half second.
    this.timer ||= setTimeout(() => {
      this.timer = null
      this.refresh()
    }, 500)
  }

  async refresh(event) {
    event?.preventDefault()
    if (!this.active || this.navigationPending) return
    if (this.dirty) {
      this.status("pending")
      return
    }
    const frame = this.element.closest("turbo-frame[src]")
    if (frame) return frame.reload()

    const { Turbo } = await import("@hotwired/turbo-rails")
    if (!this.active || this.navigationPending) return
    if (this.dirty) {
      this.status("pending")
      return
    }
    Turbo.visit(window.location.href, { action: "replace", refresh: { scroll: "preserve" } })
    // Turbo emits turbo:visit synchronously. This is our own refresh; later visits
    // and submissions take priority and clear its render protection.
    this.navigationPending = false
    this.refreshing = true
  }

  beforeRender(event) {
    if (!this.refreshing) return
    const render = event.detail.render
    event.detail.render = (...args) => {
      // A draft can start after the GET, or while Turbo prepares the new body.
      // Finish the visit without replacing it; clearing the draft requests fresh state.
      if (this.dirty) this.status("pending")
      else return render(...args)
    }
  }

  status(name) {
    if (this.hasStatusTarget) this.statusTarget.textContent = this.statusTarget.dataset[name]
  }
}
