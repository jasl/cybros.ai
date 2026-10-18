// getRandomValues also works on the explicitly supported LAN HTTP surface;
// randomUUID is restricted to secure contexts.
export function uuidv7() {
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  bytes[6] = (bytes[6] & 0x0f) | 0x70;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const time = Date.now().toString(16).padStart(12, "0");
  const random = Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
  return `${time.slice(0, 8)}-${time.slice(8)}-${random.slice(12, 16)}-${random.slice(16, 20)}-${random.slice(20)}`;
}
