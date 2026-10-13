# Files, images and memory

## Files and attachments

Attach files with repeatable `rho run --attach PATH` options or by sending a file in Telegram. The daemon must be able to read CLI attachment paths. Documents keep a Nexus upload reference; the model can import them into the selected runner, inspect them with its tools and publish an output file.

The browser shows linked artifacts and downloads them through rho, including artifacts on a separate runner. **Browser file upload is not currently available**: use CLI attachments, Telegram, or files already present on the runner.

When rho creates a file for you, it publishes the result with `file_publish`. The reply shows the published file as a downloadable attachment; a remote filesystem path alone is not a download link. A parent reply also includes files from the exact Subagent results it accepted, so the parent need not publish those files again. Telegram sends these files with the parent report unless the worker has its own selected result destination.

Installing rho on a host does not install every document parser or project dependency. The published Docker image includes language toolchains, Chromium, document conversion tools, fonts and Python file-work libraries, described to the model by its installed `workspace-tools` skill.

## Images

Image input depends on the selected model's capabilities; keeping an attachment does not imply that a model can view its media type. To generate or edit images, set the image model under **Plugins → Images** to an available image-generation model.

## Memory

Ask rho to remember a preference, a confirmed fact or a project decision, or to forget an existing note. The assistant uses Nexus's memory tools during ordinary work and searches relevant memory when a request needs it. Memory is stored as logical documents bound to the conversation's context — conversation notes, shared workspace knowledge, the answering agent's own notes, and its notes about the current person under `speaker/` — separate from working files and from the full conversation history.

Every Bot remembers a person separately. Your private Bot uses the same `speaker/` memory for you that an external Bot uses for each visitor. External Bots can update conversation and Speaker notes, read shared workspace knowledge, and cannot read Agent-private or Human-owned memory.

Inspect the documents from the terminal:

```sh
rho memory CONVERSATION_ID ls
rho memory CONVERSATION_ID read conversation/project.md
rho memory CONVERSATION_ID grep deployment
```

Use a path returned by `ls`. The same command supports `write`, `edit` and `delete`. The daemon uses a known conversation's original workspace; if an older conversation is not found after switching workspaces, select its original workspace and retry.

All actions accept `--speaker SPEAKER_UUID` to select an unbound `speaker/` root, with existing bindings and root permissions still enforced. Without it, a conversation answered by the Main Agent uses the owner's Speaker; other conversations require an explicit selector for unbound Speaker notes.

A model saying it remembered something should be backed by a successful memory operation. Memory guidance does not guarantee that every model records or recalls every relevant fact.

## Background memory review

Optional memory review updates one chosen document with stable notes and a dated index of past work after completed replies. Enable it from the conversation's title menu or the terminal:

```sh
rho memory-review CONVERSATION_ID enable --path speaker/review.md
rho memory-review CONVERSATION_ID status --json
rho memory-review CONVERSATION_ID disable
```

Choose a writable root already bound to that conversation; a shared conversation can use `conversation/review.md`. For the Main Agent, `speaker/review.md` selects your own notes. For a Bot's unbound Speaker root, pass `--speaker SPEAKER_UUID` to select a person explicitly. Enabling starts with future replies and does not extract existing history. Review uses the completed reply's model unless `--model PROVIDER/MODEL` is given and can incur model charges. **Plugins → Memory review** also offers **Review every conversation** as the default for conversations that have not chosen; a Speaker destination then selects the first completed reply's captured Speaker.

A Speaker review remains attached to that selected person's document. Replies from another Speaker do not update it, and review does not bind the conversation's other participants to that person. Enable review again with an explicit Speaker to choose another document, or choose conversation memory for shared notes.

Review keeps the source conversation's access rules. A failed review leaves its answer and previous memory intact. A newer edit makes a stale review skip its write. Deleting the selected document stops automatic writes until you explicitly enable review again; deleting a note does not delete the original conversation.
