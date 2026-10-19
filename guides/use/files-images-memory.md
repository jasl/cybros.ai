# Files, images and memory

## Files and attachments

Attach files with repeatable `rho run --attach PATH` options or by sending a file in Telegram. The daemon must be able to read CLI attachment paths. Documents keep a Nexus upload reference; the model can import them into the selected runner, inspect them with its tools and publish an output file.

The browser shows linked artifacts and downloads them through rho, including artifacts on a separate runner. **Browser file upload is not currently available**: use CLI attachments, Telegram, or files already present on the runner.

When rho creates a file for you, it publishes the result with `file_publish`. The reply shows the published file as a downloadable attachment; a remote filesystem path alone is not a download link. A parent reply also includes files from the exact Subagent results it accepted, so the parent need not publish those files again. Telegram sends these files with the parent report unless the worker has its own selected result destination.

Installing rho on a host does not install every document parser or project dependency. The published Docker image includes language toolchains, Chromium, document conversion tools, fonts and Python file-work libraries, described to the model by its installed `workspace-tools` skill.

## Review working directory changes

Open a Conversation in the WebUI and expand **Review working directory changes** below its transcript. The read runs on that Conversation's selected Runner, using its bound Git directory or that Runner's default directory. The panel shows the repository root, Runner and exact commit used for comparison.

1. Select **Refresh against HEAD** to compare tracked and untracked files with the current commit. Staged and unstaged changes appear together. A repository needs an initial commit.
2. Choose a changed file, then a removed or added line. Write a comment and choose **Add feedback to message**.
3. Review the ordinary message draft and send it. Feedback includes the original path, side, line, code excerpt and commit. It does not change files or approve tool effects.

Adding feedback rechecks the file. If it changed or the read fails, a warning appears and the comment retains its original excerpt. The working directory can change again afterward; the displayed diff is a captured comparison, not a live editor. It includes human and other task edits too, rather than claiming every change came from this Conversation.

Each read lists at most 200 files with a bounded filename window; each file patch is limited to 32 KiB. Binary and oversized patches show explicit unavailable states. Non-Git directories, missing commits and unreachable Runners show errors. A bound subdirectory is resolved to its Git repository root. Historical checkpoint comparisons and worktree management are separate from this view.

Unsent review comments stay in the page under their Conversation and Runner. Adding a comment copies it into that Conversation's existing message draft; neither draft survives closing the page. An uncertain send can be retried with its original key within 24 hours. After that window the page stops retrying and asks you to check history before composing a new message.

## Images

Image input depends on the selected model's capabilities; keeping an attachment does not imply that a model can view its media type. To generate or edit images, set the image model under **Plugins → Images** to an available image-generation model.

rho captures that choice in each execution's declaration. Nexus generates the
images and keeps the results as downloadable attachments, so an accepted image
call can finish while rho is offline. Reference images must already be uploaded;
the Runner's file tools import local files before the image call. rho displays
the retained result when it reconnects.

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

Background memory review runs in rho and requires the daemon to be online.
