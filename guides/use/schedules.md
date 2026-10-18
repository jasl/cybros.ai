# Schedules

A scheduled job saves an instruction on a conversation and runs it later, once or on a recurrence. Nexus stores the schedule and starts each occurrence in a fresh child conversation; the result reports back to the original conversation.

## In the browser

Open **Schedules** in a conversation. Create a one-time job, an interval with its first execution time, or a daily time with an IANA time zone. The panel lists jobs and supports edits, pause, resume, cancellation and execution history. Telegram provides the corresponding `/job` commands.

## From the terminal

```sh
rho jobs CONVERSATION_ID create once in 30m Check the build and report here
rho jobs CONVERSATION_ID create every 2h Review incoming changes
rho jobs CONVERSATION_ID create daily 09:00 Asia/Shanghai Summarize progress
rho jobs CONVERSATION_ID list
rho jobs CONVERSATION_ID history JOB_ID
rho jobs CONVERSATION_ID pause JOB_ID
rho jobs CONVERSATION_ID resume JOB_ID
rho jobs CONVERSATION_ID cancel JOB_ID
```

Use `--workspace WORKSPACE_ID` for a conversation outside the current default workspace, `--model PROVIDER/MODEL` to select a model when creating a job, and `--json` for structured output. Absolute one-time dates need `Z` or an explicit UTC offset.

## Behavior

- Each occurrence runs in a new child conversation while the main conversation may keep working. The child's original answer queues for the main conversation and is delivered when it can answer.
- A job permits one unfinished execution at a time. A due occurrence is skipped while the previous one is still running; missed occurrences after downtime coalesce into one.
- **Pause and cancel affect future occurrences.** Stop an already running child inside its execution.
- A one-time schedule marked `completed` has been dispatched; its child may still be running. Execution history shows the child's actual status.
- Jobs created through rho use the Main conversation's Code mode and Subagent choices, or the Bot's current mode settings when selecting their tools. Changing those choices later does not rewrite existing jobs.

Keep Nexus, its workers, and any selected Runner, model or MCP service available.
Jobs using only those services continue while rho is offline. A job that selects
code mode, a rho-served tool or an application hook still needs that application.
The API behind this feature is described in [Schedules](../build/schedules.md).
