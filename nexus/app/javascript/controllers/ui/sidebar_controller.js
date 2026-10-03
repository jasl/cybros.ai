import { Controller } from "@hotwired/stimulus"

// Desktop collapse for the console sidebar. The state is mirrored into a
// cookie so the server renders the collapsed shell on the next request and
// Turbo visits never flash the wrong sidebar state.
export default class extends Controller {
  static targets = ["drawer", "opener", "closer", "expander", "collapser", "content", "side"]
  static values = { collapsed: Boolean }

  connect() {
    this.desktop = window.matchMedia("(min-width: 64rem)")
    this.onBreakpoint = (event) => {
      if (event.matches) this.drawerTarget.checked = false
      this.applyDrawerState(this.drawerTarget.checked, false)
    }
    this.desktop.addEventListener("change", this.onBreakpoint)
    this.applyDrawerState(this.drawerTarget.checked, false)
  }

  disconnect() {
    this.desktop.removeEventListener("change", this.onBreakpoint)
  }

  toggle() {
    this.collapsedValue = !this.collapsedValue
    // Stimulus fires collapsedValueChanged from a MutationObserver
    // microtask; apply immediately so the control we move focus to is
    // already visible.
    this.applyCollapsedState(this.collapsedValue)
    document.cookie = `sidebar_collapsed=${this.collapsedValue ? "1" : "0"}; path=/; max-age=31536000; samesite=lax`
    this.focusVisibleToggle()
  }

  collapsedValueChanged(collapsed) {
    this.applyCollapsedState(collapsed)
  }

  openDrawer() {
    if (!this.drawerTarget.checked) this.drawerTarget.click()
  }

  closeDrawer() {
    if (this.drawerTarget.checked) this.drawerTarget.click()
  }

  // Mobile drawer accessibility: opening moves focus into the drawer and
  // inerts the page behind the overlay; closing restores focus to the opener.
  syncDrawer(event) {
    this.applyDrawerState(event.target.checked, true)
  }

  applyDrawerState(open, moveFocus) {
    const mobile = !this.desktop.matches
    if (this.hasContentTarget) this.contentTarget.inert = mobile && open
    if (this.hasSideTarget) this.sideTarget.inert = mobile && !open
    if (this.hasOpenerTarget) this.openerTarget.setAttribute("aria-expanded", open.toString())

    if (!moveFocus || !mobile) return

    const target = open
      ? (this.hasCloserTarget && this.closerTarget)
      : (this.hasOpenerTarget && this.openerTarget)
    if (target) this.focusDrawerControl(target)
  }

  focusDrawerControl(target) {
    const focus = () => target.focus()
    focus()
    if (document.activeElement === target) return

    // daisyUI keeps the drawer visibility transition discrete. If the open
    // control is not focusable yet, retry when the drawer itself finishes
    // becoming visible; reduced-motion/no-transition rendering succeeds on
    // the immediate or next-frame attempt instead.
    const onTransitionEnd = (event) => {
      if (event.target !== this.sideTarget) return

      this.sideTarget.removeEventListener("transitionend", onTransitionEnd)
      focus()
    }
    this.sideTarget.addEventListener("transitionend", onTransitionEnd)
    requestAnimationFrame(() => {
      focus()
      if (document.activeElement === target) {
        this.sideTarget.removeEventListener("transitionend", onTransitionEnd)
      }
    })
  }

  applyCollapsedState(collapsed) {
    this.element.classList.toggle("lg:drawer-open", !collapsed)
    this.element.classList.toggle("is-collapsed", collapsed)
    if (this.hasExpanderTarget) {
      this.expanderTarget.classList.toggle("lg:inline-flex", collapsed)
    }
  }

  // The activated toggle hides itself, which would drop keyboard focus to
  // <body>; hand focus to the counterpart control instead.
  focusVisibleToggle() {
    const target = this.collapsedValue
      ? (this.hasExpanderTarget && this.expanderTarget)
      : (this.hasCollapserTarget && this.collapserTarget)
    if (target) this.focusDrawerControl(target)
  }
}
