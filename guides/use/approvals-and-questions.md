# Approvals and questions

Two kinds of pause need a person. Both appear beside the work in the browser, in Telegram, and in an ACP editor; both hold the reply until decided.

## Tool approvals

Every tool call crosses an approval stage in Nexus. rho's rules decide most calls automatically: read-only tools and ordinary commands run, destructive shapes are refused with a reason the model reads, and the rest wait for you. A waiting call shows its tool, its input and the effect it declares. Choose **Approve** or **Deny**.

- A parked call waits up to 24 hours. After that it fails as expired and the model is told nobody approved it.
- Denying is data: the model reads the refusal and can choose another approach.
- Stop cancels parked calls with the rest of the unstarted work.

`rho run` in the terminal cannot ask you: it denies calls that would park and lets the model continue. Use an interactive entry point for work that needs decisions.

rho's rule list and its approval mode are application settings; the grammar and the modes are described in [Approvals and rules](../build/approvals-and-rules.md).

## Questions

The agent can ask a question with options or free text. A foreground question holds the reply; a question from background work holds only that branch and stays answerable from its originating run after newer turns start. An unanswered question expires after its deadline and the run then needs a decision — retry, abandon or append a repair — rather than silently succeeding.

In rho WebUI, a structured question shows labelled text, number, yes/no, single-choice or multiple-choice fields. Fill the required fields and choose **Send answer**. For an optional field, select **Answer …** to include it; leave it unchecked to skip it. An included empty text or empty multiple-choice answer is different from skipping the field. **No** and **0** remain boolean and numeric answers.

Invalid numbers are shown beside their fields. A failed submission keeps your entries so you can correct or retry them. Draft entries last while you stay in the conversation; reloading the page restores the pending question, but not unsent entries. Long forms scroll inside the question card while **Send answer** stays visible. After Nexus accepts the answer, the agent continues and the ordinary message composer returns.

Bot conversations remain read-only in WebUI. Telegram and the terminal do not render these structured forms; their notices identify that limitation. Answering a question does not approve a tool call.

## Attention holds

When a task fails and its policy says to halt, the run finishes whatever can still run and then waits for a person. The conversation shows the failed task and its reason. You can:

- **Retry** the failed task, optionally with another model.
- **Abandon** it so the run moves past the failure.
- Send a new message, which starts new work with the current configuration.

A hold has no clock: a run waiting for you stands until you decide.

## Where rules live

- **Plugins** holds rho's tool plugins and their settings, including code mode.
- rho's approval rules are managed by the application; a person's own commands entered from the terminal are never re-prompted.
- Nexus freezes the mode and rules onto each run when it starts, so changing settings affects later turns, not running ones.
