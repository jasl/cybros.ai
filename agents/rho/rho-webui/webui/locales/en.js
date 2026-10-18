import shell from "./en/shell.js";
import conversation from "./en/conversation.js";
import settings from "./en/settings.js";
import nexus from "./en/nexus.js";

// Human-facing copy and product names belong to this one catalog; the parts
// only keep each file small. A key defined twice is a test failure.
export default { ...shell, ...conversation, ...settings, ...nexus };
