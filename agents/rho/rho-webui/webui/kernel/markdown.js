// A deliberately small display vocabulary. Model output never becomes HTML:
// unsupported Markdown and raw tags remain readable text. Files from a runner
// use the authenticated artifact reader, not Markdown image requests.
const element = (tag, text) => {
  const node = document.createElement(tag);
  if (text !== undefined) node.textContent = text;
  return node;
};

function linkTarget(value) {
  try {
    const url = new URL(value);
    return ["https:", "http:", "mailto:"].includes(url.protocol) ? url.href : null;
  } catch { return null; }
}

function inline(text) {
  const fragment = document.createDocumentFragment();
  const tokens = /(`+)([^`\n]+?)\1|\*\*([^*\n]+)\*\*|__([^_\n]+)__|\*([^*\n]+)\*|\[([^\]\n]+)\]\(([^\s)]+)\)/g;
  let cursor = 0;
  for (const match of text.matchAll(tokens)) {
    fragment.append(text.slice(cursor, match.index));
    if (match[1]) fragment.append(element("code", match[2]));
    else if (match[3] || match[4]) fragment.append(element("strong", match[3] || match[4]));
    else if (match[5]) fragment.append(element("em", match[5]));
    else {
      const href = linkTarget(match[7]);
      if (href) {
        const link = element("a", match[6]);
        link.href = href;
        link.target = "_blank";
        link.rel = "noopener noreferrer";
        fragment.append(link);
      } else fragment.append(match[0]);
    }
    cursor = match.index + match[0].length;
  }
  fragment.append(text.slice(cursor));
  return fragment;
}

const fence = (line) => /^ {0,3}(`{3,}|~{3,})([^`]*)$/.exec(line);
const heading = (line) => /^ {0,3}(#{1,6})\s+(.+)$/.exec(line);
const item = (line) => /^\s*(?:([-+*])|\d+[.)])\s+(.+)$/.exec(line);
const quote = (line) => /^ {0,3}>\s?(.*)$/.exec(line);
const rule = (line) => /^ {0,3}(?:-{3,}|\*{3,}|_{3,})\s*$/.test(line);
const block = (line) => fence(line) || heading(line) || item(line) || quote(line) || rule(line);

function tableCells(line) {
  const cells = [""];
  for (let i = 0; i < line.length; i++) {
    const char = line[i];
    if (char === "\\" && ["|", "\\"].includes(line[i + 1])) {
      // Escaped pipes belong to a cell, including inside inline code.
      cells[cells.length - 1] += line[++i] === "|" ? "|" : "\\\\";
    } else if (char === "|") cells.push("");
    else cells[cells.length - 1] += char;
  }
  if (cells.length > 1 && !cells[0].trim()) cells.shift();
  if (cells.length > 1 && !cells.at(-1).trim()) cells.pop();
  return cells.map((cell) => cell.trim());
}

function tableHeader(lines, index) {
  if (!lines[index]?.includes("|") || !lines[index + 1]?.includes("|")) return null;
  const headers = tableCells(lines[index]);
  const separators = tableCells(lines[index + 1]);
  if (headers.length !== separators.length || !separators.every((cell) => /^:?-+:?$/.test(cell))) return null;
  return { headers, align: separators.map((cell) => cell.endsWith(":") ? (cell.startsWith(":") ? "center" : "right") : "left") };
}

export function markdown(value) {
  const fragment = document.createDocumentFragment();
  const lines = String(value ?? "").replace(/\r\n?/g, "\n").split("\n");
  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    if (!line.trim()) { i++; continue; }
    const start = fence(line);
    if (start) {
      const code = [];
      const marker = start[1][0];
      const length = start[1].length;
      i++;
      while (i < lines.length) {
        const close = lines[i].trim();
        if (close.length >= length && [...close].every((char) => char === marker)) { i++; break; }
        code.push(lines[i++]);
      }
      const pre = element("pre");
      pre.append(element("code", code.join("\n")));
      fragment.append(pre);
      continue;
    }
    const columns = tableHeader(lines, i);
    if (columns) {
      const table = element("table");
      const row = (values, tag) => {
        const tr = element("tr");
        columns.headers.forEach((_, index) => {
          const cell = element(tag);
          if (tag === "th") cell.setAttribute("scope", "col");
          cell.style.textAlign = columns.align[index];
          cell.append(inline(values[index] ?? ""));
          tr.append(cell);
        });
        return tr;
      };
      const head = element("thead");
      head.append(row(columns.headers, "th"));
      const body = element("tbody");
      i += 2;
      while (i < lines.length && lines[i].trim() && !block(lines[i])) body.append(row(tableCells(lines[i++]), "td"));
      table.append(head, body);
      const scroll = element("div");
      scroll.className = "markdown-table";
      scroll.setAttribute("tabindex", "0");
      scroll.append(table);
      fragment.append(scroll);
      continue;
    }
    const title = heading(line);
    if (title) {
      // The surrounding page owns h1; answer headings begin at h2.
      const node = element(`h${Math.min(title[1].length + 1, 6)}`);
      node.append(inline(title[2]));
      fragment.append(node);
      i++;
      continue;
    }
    if (rule(line)) { fragment.append(element("hr")); i++; continue; }
    const first = item(line);
    if (first) {
      const unordered = Boolean(first[1]);
      const list = element(unordered ? "ul" : "ol");
      while (i < lines.length) {
        const next = item(lines[i]);
        if (!next || Boolean(next[1]) !== unordered) break;
        const li = element("li");
        li.append(inline(next[2]));
        list.append(li);
        i++;
      }
      fragment.append(list);
      continue;
    }
    if (quote(line)) {
      const quoted = [];
      while (i < lines.length && quote(lines[i])) quoted.push(quote(lines[i++])[1]);
      const node = element("blockquote");
      node.append(inline(quoted.join("\n")));
      fragment.append(node);
      continue;
    }
    const paragraph = [lines[i++]];
    while (i < lines.length && lines[i].trim() && !block(lines[i]) && !tableHeader(lines, i)) paragraph.push(lines[i++]);
    const node = element("p");
    node.append(inline(paragraph.join("\n")));
    fragment.append(node);
  }
  return fragment;
}
