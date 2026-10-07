# Tool assembly

`POST /agent_api/v1/tools/assembly` projects the callable tool declarations and
environment that new work would receive from an Agent's selected sources. It
uses the same assembly mechanism as execution. It creates no Conversation,
Run, Task, job, or model request, and changes no profile or Runner selection.

```http
POST /agent_api/v1/tools/assembly
```

The caller must present an Agent's member credential. A Human member receives
`403 not_agent`; an absent, rejected, or executor credential receives
`401 unauthorized`.

## Request

`default_runner_executor_public_id` is required and nullable. A UUID selects
that eligible Runner; `null` selects no Runner. The server does not choose a
candidate on the application's behalf.

Omit `configuration` to use the authenticated Agent's current
[Profile declaration](profile.md):

```json
{
  "default_runner_executor_public_id": null
}
```

To inspect another declaration without saving it, provide `configuration` as
an object with these fields:

| Field | Meaning |
| --- | --- |
| `tool_definitions` | Explicit function declarations and compact kernel aliases; omitted, `null`, or `[]` means none. |
| `kernel_tools` | Exact canonical kernel names to import; omitted, `null`, or `[]` imports none. |
| `runner_executor_public_ids` | Ordered, unique Runner UUID candidates; omitted, `null`, or `[]` declares none. |
| `runner_tool_names` | Exact served-name allowlist intersected with the selected Runner's model announcements; omitted or `null` imports all its model tools, while `[]` imports none. Unavailable names contribute no tool. |

An explicit configuration replaces the profile's sources for this request;
it is not a patch. An empty object assembles no tools. Other configuration
fields are ignored. The same declaration, import, and size validation rules
apply as on the Profile. Explicit tools and aliases remain enabled when
`kernel_tools` is empty.

```json
{
  "default_runner_executor_public_id": "01900000-0000-7000-8000-000000000051",
  "configuration": {
    "tool_definitions": [],
    "kernel_tools": ["nexus.memory.read"],
    "runner_executor_public_ids": ["01900000-0000-7000-8000-000000000051"],
    "runner_tool_names": ["read"]
  }
}
```

The selected Runner must occur in the declaration's candidate list and remain
eligible for the caller. Eligibility uses current lifecycle, credentials, and
assignment scope; socket presence does not select or reject a Runner.
Only that Runner contributes imported tools. Operator-only announcements
without model descriptions or schemas are excluded. A nonempty
`runner_tool_names` imports only exact matches in that Runner's model
announcements; it does not require every allowlisted tool to be installed or
import missing tools from other candidates.

## Response

Success is `200` with two fields:

```json
{
  "tool_definitions": [],
  "environment": {
    "default_runner_executor_public_id": null,
    "executors": [],
    "runner_candidates": []
  }
}
```

`tool_definitions` contains the complete, rendered declarations in canonical
callable-name order, including alias facts, Runner routes, and any
`defer_loading` annotation. This is the execution declaration, before provider
projection. An imported Runner tool retains its announced schema and served
name. A name collision receives a stable qualified callable name; applications
should use the returned name rather than derive it themselves.

Each row in `environment.executors` and `environment.runner_candidates` has
`runner_executor_public_id`, `display_name`, and the Runner's announced
`environment` object. `executors` describes the selected Runner and any Runner
referenced by an explicit tool route. `runner_candidates` lists currently
eligible candidates in the declaration's order. Ineligible or unknown
candidates contribute no metadata. Explicit Runner routes retain their own
eligibility and served-tool checks.

The result is an observation of current declarations and announcements, not a
reservation or saved execution snapshot. Use its callable names to construct
a new input's `tool_names`; the later creation path assembles and freezes its
own current declarations. Repeating this read after configuration changes may
return a different result. No idempotency key is required.

## Refusals

Errors use the [Agent API error envelope](../v1.md#errors).

| Status | Code | Meaning |
| --- | --- | --- |
| `400` | `parameter_missing` | The nullable Runner selector is absent, or a present configuration is not an object. |
| `401` | `unauthorized` | No accepted Agent API member credential. |
| `403` | `not_agent` | The member is not an Agent. |
| `422` | `validation_failed` | An explicit configuration fails the declaration or import grammar; the message names the field and validation code. |
| `422` | `runner_not_declared` | The selected Runner is outside the declared candidate list. |
| `422` | `runner_not_eligible` | A selected or explicitly routed Runner is unknown or not currently eligible. |
| `422` | `tool_not_served` | An explicit concrete Runner route names a tool not offered by its target. |
| `413` | `content_too_large` | The assembled declarations exceed the shared tool-declaration bound. |

Other declaration-grammar refusals, such as `duplicate_tool_name`, use `422`.
Refused assembly returns no tool or environment projection.

The Ruby SDK exposes this read as
`client.tools.assemble(default_runner_executor_public_id: nil, configuration: nil)`
and returns `Api::ToolAssembly` with `tool_definitions` and `environment`.
