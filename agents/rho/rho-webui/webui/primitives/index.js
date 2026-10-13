// The shared control vocabulary. Modules reach it as `ui.primitives`; the
// shell and its features import it directly. One implementation each.
export { button, iconButton, icon } from "./button.js";
export { field, input, textarea, select, checkbox, switchControl, segmented, stepper } from "./field.js";
export { alert, tag, stateDot, spinner, skeleton, emptyState, namedMark, glyphMark } from "./feedback.js";
export { disclosure } from "./disclosure.js";
export { section, group, formGroup, list, link } from "./section.js";
export { menuButton, openMenu } from "./menu.js";
export { modal } from "./modal.js";
export { panelRow, page } from "./navigation.js";

import * as buttons from "./button.js";
import * as fields from "./field.js";
import * as feedback from "./feedback.js";
import { disclosure } from "./disclosure.js";
import * as sections from "./section.js";
import { menuButton, openMenu } from "./menu.js";
import { modal } from "./modal.js";
import { panelRow, page } from "./navigation.js";

export const primitives = Object.freeze({
  button: buttons.button, iconButton: buttons.iconButton, icon: buttons.icon,
  field: fields.field, input: fields.input, textarea: fields.textarea, select: fields.select, checkbox: fields.checkbox,
  switchControl: fields.switchControl, segmented: fields.segmented, stepper: fields.stepper,
  alert: feedback.alert, tag: feedback.tag, stateDot: feedback.stateDot, spinner: feedback.spinner, skeleton: feedback.skeleton,
  emptyState: feedback.emptyState, namedMark: feedback.namedMark, glyphMark: feedback.glyphMark,
  disclosure,
  section: sections.section, group: sections.group, formGroup: sections.formGroup, list: sections.list, link: sections.link,
  menuButton, openMenu, modal,
  panelRow, page,
});
