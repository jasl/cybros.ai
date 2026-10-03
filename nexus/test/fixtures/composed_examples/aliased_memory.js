const reader = g.model({ prompt: "Read " + params.path, tools: ["ReadNote"], key: "reader" });
g.model({ prompt: "Summarize the note.", results: [reader], key: "summary" });
