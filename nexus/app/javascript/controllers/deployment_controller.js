import { Controller } from "@hotwired/stimulus"

const PENDING_KEY = "nexus.deployment.pending"
const MAX_FAILURES = 20
const MAX_LOG_CHARS = 131072

// The stream is an observation of an installation receipt. EOF and network
// failures reconnect with its cursor; neither can issue an upgrade command.
export async function readProgress(response, receive) {
  const reader = response.body.getReader()
  const decoder = new TextDecoder()
  let pending = ""
  try {
    while (true) {
      const { value, done } = await reader.read()
      pending += decoder.decode(value, { stream: !done })
      pending = pending.replace(/\r\n/g, "\n")
      let end
      while ((end = pending.indexOf("\n\n")) >= 0) {
        const event = pending.slice(0, end)
        pending = pending.slice(end + 2)
        const lines = event.split("\n")
        const name = lines.find(line => line.startsWith("event:"))?.slice(6).trim()
        const data = lines.filter(line => line.startsWith("data:")).map(line => line.slice(5).trimStart()).join("\n")
        if (data && receive(name, JSON.parse(data)) === false) return
      }
      if (pending.length > 262144) throw new Error("The progress response is too large.")
      if (done) return
    }
  } finally {
    await reader.cancel().catch(() => {})
    reader.releaseLock()
  }
}

export default class extends Controller {
  static targets = ["notice", "checkButton", "upgradeButton", "upgradeForm", "pendingActions",
    "progress", "phase", "status", "targetRelease", "updatedAt", "connection", "operationError",
    "recovery", "log", "reconnect", "reload", "databaseBackup", "backupCreatedAt", "backupSize", "backupAvailability",
    "backupChoice", "backupField", "backupCheckNotice", "backupDetails", "backupHelp"]
  static values = { statusUrl: String, upgradesUrl: String, pageUrl: String, upgradePagesUrl: String,
    receipt: Object, phaseLabels: Object, statusLabels: Object, messages: Object, locale: String,
    upgradeReady: Boolean, checkedBackup: Boolean }

  connect() {
    this.abort = new AbortController()
    this.failures = 0
    this.cursor = null
    this.logParts = []
    this.pending = this.readPending()
    if (this.pending && this.hasBackupChoiceTarget) {
      this.backupChoiceTarget.checked = this.pending.backup
      this.backupChanged()
    }
    if (this.receiptValue?.id) this.follow(this.receiptValue, { navigate: false })
    if (this.pending) this.recover()
  }

  disconnect() {
    clearTimeout(this.timer)
    this.abort.abort()
    this.observer?.abort()
  }

  async check(event) {
    event.preventDefault()
    this.setBusy(true)
    this.notice(this.messagesValue.checking)
    try {
      const response = await this.request(event.currentTarget.action, {
        method: "POST", body: JSON.stringify({ release_check: { backup: this.backupChoiceTarget.checked } }),
      }, 130000)
      if (response.ok) window.location.assign(this.pageUrlValue)
      else this.notice(await this.errorMessage(response, this.messagesValue.check_incomplete))
    } catch {
      if (!this.abort.signal.aborted) this.notice(this.messagesValue.check_unavailable)
    } finally {
      this.setBusy(Boolean(this.operation?.status === "running" || this.pending))
    }
  }

  async upgrade(event) {
    event.preventDefault()
    if (this.pending) return this.recover()
    if (!this.upgradeReadyValue || this.backupChoiceTarget.checked !== this.checkedBackupValue) return

    const fields = new FormData(event.currentTarget)
    const references = fields.getAll("candidate[images][][reference]")
    this.pending = {
      idempotency_key: fields.get("idempotency_key"),
      backup: this.backupChoiceTarget.checked,
      candidate: {
        release: fields.get("candidate[release]"),
        images: fields.getAll("candidate[images][][name]").map((name, index) => ({ name, reference: references[index] })),
      },
    }
    this.savePending()
    await this.submitPending()
  }

  async retry() {
    if (this.pending && !this.submitting) await this.submitPending()
  }

  async submitPending() {
    this.submitting = true
    this.setBusy(true)
    this.pendingActionsTarget.hidden = true
    this.notice(this.messagesValue.submitting)
    try {
      const response = await this.request(this.upgradePagesUrlValue, {
        method: "POST", body: JSON.stringify(this.pending),
      })
      if (response.ok) {
        const { upgrade } = await response.json()
        this.clearPending()
        this.notice("")
        this.follow(upgrade)
      } else if (response.status >= 500) {
        this.unknownRequest()
        await this.recover()
      } else {
        const body = await response.json().catch(() => null)
        this.notice(body?.error?.message || this.messagesValue.request_refused)
        this.clearPending()
        if (body?.error?.code === "preflight_failed") this.upgradeReadyValue = false
        this.setBusy(false)
        if (body?.error?.code === "preflight_failed") window.location.assign(this.pageUrlValue)
      }
    } catch {
      if (!this.abort.signal.aborted) {
        this.unknownRequest()
        await this.recover()
      }
    } finally {
      this.submitting = false
    }
  }

  unknownRequest() {
    this.notice(this.messagesValue.request_unknown)
    this.pendingActionsTarget.hidden = false
  }

  async recover() {
    clearTimeout(this.timer)
    if (!this.pending) return
    this.setBusy(true)
    try {
      const response = await this.request(this.statusUrlValue)
      if (response.status === 401 || response.status === 403) return this.authorizationEnded()
      if (!response.ok) throw new Error("Updater unavailable")

      const { deployment } = await response.json()
      const receipt = [deployment.active_operation, deployment.last_operation]
        .find(operation => operation?.idempotency_key === this.pending.idempotency_key)
      this.failures = 0
      if (receipt) {
        this.clearPending()
        this.notice("")
        this.follow(receipt)
      } else {
        this.notice(this.messagesValue.request_missing)
        this.pendingActionsTarget.hidden = false
      }
    } catch {
      if (!this.abort.signal.aborted) this.schedule(() => this.recover(), true)
    }
  }

  follow(receipt, { navigate = true } = {}) {
    clearTimeout(this.timer)
    this.observer?.abort()
    this.observer = new AbortController()
    this.failures = 0
    if (this.operation?.id !== receipt.id) {
      this.cursor = null
      this.logParts = []
      this.logTarget.textContent = ""
    }
    this.updateReceipt(receipt)
    if (navigate) window.history.replaceState(window.history.state, "", `${this.upgradePagesUrlValue}/${encodeURIComponent(receipt.id)}`)
    this.observe()
  }

  async observe() {
    const observer = this.observer
    const url = new URL(`${this.upgradesUrlValue}/${encodeURIComponent(this.operation.id)}/stream`, window.location.origin)
    if (this.cursor) url.searchParams.set("cursor", this.cursor)
    let finished = false
    let failed = false
    try {
      const response = await this.request(url, { headers: { Accept: "text/event-stream" } }, 30000, observer.signal)
      if (response.status === 401 || response.status === 403) return this.authorizationEnded()
      if (!response.ok) throw new Error("Progress unavailable")

      await readProgress(response, (event, payload) => {
        if (event === "deployment.error.v1") {
          if (payload.code === "administrator_required") {
            this.authorizationEnded()
            finished = true
          } else {
            failed = true
          }
          return false
        }
        if (event === "deployment.progress.v1") {
          this.failures = 0
          this.updateReceipt(payload.operation)
          this.appendLog(payload.entries)
          this.cursor = payload.next_cursor
          finished = payload.operation.status !== "running" &&
            (this.cursor === payload.operation.log_cursor || payload.entries.length === 0)
          this.connectionTarget.textContent = finished ? this.messagesValue.result_saved : this.messagesValue.following
          return !finished
        }
        return true
      })
    } catch {
      failed = true
    }
    if (!finished && !observer.signal.aborted && !this.abort.signal.aborted) {
      this.schedule(() => this.observe(), failed)
    }
  }

  schedule(callback, failed) {
    clearTimeout(this.timer)
    if (failed) this.failures += 1
    if (this.failures >= MAX_FAILURES) {
      this.connectionTarget.textContent = this.messagesValue.reconnect_paused
      this.reconnectTarget.hidden = false
      return
    }
    if (failed) this.connectionTarget.textContent = this.messagesValue.reconnecting
    const delay = failed ? Math.min(1000 * (2 ** Math.min(this.failures, 4)), 15000) : 1000
    this.timer = setTimeout(callback, delay)
  }

  reconnect() {
    this.failures = 0
    this.reconnectTarget.hidden = true
    if (this.pending) this.recover()
    else if (this.operation) this.follow(this.operation)
  }

  updateReceipt(receipt) {
    this.operation = receipt
    this.progressTarget.hidden = false
    this.phaseTarget.textContent = this.phaseLabelsValue[receipt.phase] || receipt.phase
    this.statusTarget.textContent = this.statusLabelsValue[receipt.status] || receipt.status
    this.targetReleaseTarget.textContent = receipt.target.release
    this.updatedAtTarget.textContent = receipt.updated_at
    this.operationErrorTarget.textContent = receipt.error?.message || ""
    this.operationErrorTarget.hidden = !receipt.error
    this.recoveryTarget.textContent = receipt.recovery || ""
    this.recoveryTarget.hidden = !receipt.recovery
    this.databaseBackupTarget.hidden = receipt.backup && !receipt.database_backup
    this.backupDetailsTarget.hidden = !receipt.database_backup
    this.backupHelpTarget.hidden = !receipt.database_backup
    if (!receipt.backup) this.backupAvailabilityTarget.textContent = this.messagesValue.backup_skipped
    if (receipt.database_backup) {
      this.backupCreatedAtTarget.textContent = receipt.database_backup.created_at
      this.backupSizeTarget.textContent = this.messagesValue.backup_bytes.replace("%{size}", receipt.database_backup.size_bytes.toLocaleString(this.localeValue))
      this.backupAvailabilityTarget.textContent = receipt.database_backup.available ?
        this.messagesValue.backup_available : this.messagesValue.backup_expired
    }
    this.reloadTarget.hidden = receipt.status !== "succeeded"
    if (receipt.status === "running") this.setBusy(true)
  }

  appendLog(entries) {
    for (const entry of entries) this.logParts.push(entry.text)
    while (this.logParts.length > 1 && this.logParts.join("").length > MAX_LOG_CHARS) this.logParts.shift()
    this.logTarget.textContent = this.logParts.join("")
  }

  authorizationEnded() {
    this.observer?.abort()
    this.connectionTarget.textContent = this.messagesValue.access_ended
    this.notice(this.messagesValue.access_required)
    this.pendingActionsTarget.hidden = true
    this.reconnectTarget.hidden = true
    this.setBusy(true)
  }

  setBusy(busy) {
    if (this.hasCheckButtonTarget) this.checkButtonTarget.disabled = busy
    if (this.hasBackupChoiceTarget) this.backupChoiceTarget.disabled = busy
    if (this.hasUpgradeButtonTarget) this.upgradeButtonTarget.disabled = busy || !this.upgradeReadyValue ||
      this.backupChoiceTarget.checked !== this.checkedBackupValue
  }

  backupChanged() {
    if (this.hasBackupFieldTarget) this.backupFieldTarget.value = this.backupChoiceTarget.checked.toString()
    this.backupCheckNoticeTarget.hidden = this.backupChoiceTarget.checked === this.checkedBackupValue
    this.setBusy(Boolean(this.operation?.status === "running" || this.pending || this.submitting))
  }

  notice(message) {
    this.noticeTarget.textContent = message
    this.noticeTarget.hidden = !message
  }

  request(url, options = {}, timeout = 15000, signal = this.abort.signal) {
    return fetch(url, {
      ...options, credentials: "same-origin",
      headers: { Accept: "application/json", "Content-Type": "application/json", ...options.headers },
      signal: AbortSignal.any([signal, this.abort.signal, AbortSignal.timeout(timeout)]),
    })
  }

  async errorMessage(response, fallback) {
    try {
      return (await response.json()).error?.message || fallback
    } catch {
      return fallback
    }
  }

  readPending() {
    try {
      return JSON.parse(window.sessionStorage.getItem(PENDING_KEY) || "null")
    } catch {
      return null
    }
  }

  savePending() {
    try {
      window.sessionStorage.setItem(PENDING_KEY, JSON.stringify(this.pending))
    } catch {
      // The loaded page still holds the key if browser storage is unavailable.
    }
  }

  clearPending() {
    this.pending = null
    this.pendingActionsTarget.hidden = true
    try {
      window.sessionStorage.removeItem(PENDING_KEY)
    } catch {
      // Storage availability never changes an accepted operation.
    }
  }
}
