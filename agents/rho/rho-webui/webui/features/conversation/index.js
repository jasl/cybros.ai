import { conversationPanel } from "./panel.js";

export { createConversations } from "./controller.js";

// The conversation is the default `main` panel. Everything it shows comes
// from the session's controller (`shell.conversations`); a conversation the
// person opens elsewhere (a sidebar row, a schedule's execution, a create)
// brings this panel forward.
export function register(ui, shell) {
  const { conversations } = shell;
  ui.slots.register("main", { key: "conversation" }, () => conversationPanel({ conversations, shell }));
  const stop = conversations.onOpen(() => shell.navigate("conversation"));
  ui.signal.addEventListener("abort", stop, { once: true });
}
