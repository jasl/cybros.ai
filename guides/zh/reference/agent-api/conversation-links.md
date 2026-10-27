---
title: Conversation 关系
description: 固定 Conversation 与 Agent 端点之间的双向消息授权。
---

# Conversation 关系

[English](../../../reference/agent-api/conversation-links.md)

Conversation link 在同一 Workspace 内的两个固定 Conversation/Agent 端点之间授予普通消息投递权限。
它不授予对端历史、Task、记忆、状态、request 或取消权限。以下成员面资源遵循
[通用 API 契约](../../../reference/agent-api.md)。

## 路由

```http
GET /agent_api/v1/workspaces/{workspace_id}/conversations/{conversation_id}/links
POST /agent_api/v1/workspaces/{workspace_id}/conversations/{conversation_id}/links
GET /agent_api/v1/workspaces/{workspace_id}/conversations/{conversation_id}/links/{public_id}
POST /agent_api/v1/workspaces/{workspace_id}/conversations/{conversation_id}/links/{public_id}/closure
```

## 列出关系

`GET …/conversations/{conversation_id}/links` 接受 `state`：默认 `active`，也可为
`closed` 或 `all`。游标分页使用 `after` 和 `limit`，默认 50，最大 100。

成功返回 `200`，正文包含 `links` 和 `next_after`。每条关系包含：

- `public_id`、`workspace_public_id`。
- `endpoint`、`peer`，各自包含 `conversation_public_id` 和 `agent_public_id`。
- `state`（`active` 或 `closed`）、`created_at`、`closed_at`、`close_reason`。

`endpoint` 是当前查询 Conversation 所在的一端，`peer` 是另一端。关系有效时关闭字段为 null。
列出关系要求本地 Conversation 的读取权限，不要求对端读取权限。参数错误和资源隐藏遵循通用契约。

## 读取关系

`GET …/conversations/{conversation_id}/links/{public_id}` 无正文，UUID 必须属于本地 Conversation 的关系。
成功返回 `200` 和 `{ "link": { "…": "…" } }`，字段同列表；未知或隐藏的本地资源返回 `404`。

## 创建关系

`POST …/conversations/{conversation_id}/links` 要求 `Idempotency-Key` 请求头和三个公开 UUID：

```json
{
  "link": {
    "agent_public_id": "0198…",
    "peer_conversation_public_id": "0198…",
    "peer_agent_public_id": "0198…"
  }
}
```

调用者须对两端 Conversation 都有完整权限。两端 Agent 必须是对应 Conversation 的合格回答者，
并允许双向消息。端点必须不同、未归档、不是 Side Conversation，且位于同一 Workspace。

新关系返回 `201` 和 `link`；已存在的有效端点对返回 `200`。创建回执使用通用重放窗口。
关闭后重放旧回执仍返回原接受结果，不重新打开关系；读取关系可获得当前状态。
重新授权须使用新的幂等键和关系 UUID。

拒绝原因包括 `not_authorized`、`answerer_not_eligible`、`messaging_not_allowed`、
`conversation_archived` 和 `validation_failed`，使用通用错误封装。

## 关闭关系

`POST …/conversations/{conversation_id}/links/{public_id}/closure` 无正文，要求本地 Conversation 的完整权限。
成功返回 `200` 和当前 `link`，其中 `state: "closed"`、`closed_at` 为关闭时间、
`close_reason: "explicit"`。重复关闭保持同一条已关闭关系。未知、隐藏或权限不足遵循通用契约。

## 投递与生命周期

模型的 [send 工具](../../../reference/agent-api/run-orchestration.md) 使用 `link_public_id` 替代
`to` 和 `agent`。实际调用 Run 的 Conversation 与回答 Agent 必须匹配端点；
仅知道 UUID 不能从另一 Conversation 使用关系。

关闭和消费在关系上串行化：先关闭会阻止待处理消息启动 Turn；先消费则保留接收方的处理工作。
创建和显式关闭各向两端本地事件流发布一次 `conversation_link_changed`，包含关系 UUID、状态、
关闭原因及操作者（`by` 公共 UUID、`kind`）。创建重放和重复关闭不追加事件。主体暂停/移除、负责人转移、
失去端点完整权限、失去 Workspace 访问或删除端点也会关闭相关关系。恢复权限不会重开旧关系。
消息策略变化和 Archive 保留已有关系。批量权限变化使用其现有权限通知，不逐关系发送事件。

关闭在切断许可后返回；有界恢复随后移除尚未消费的关联 Input，包括延迟、阻塞和 steering 行。
已接受的 request 及正式结果不依赖关系继续存在。

模型工具 `links({state?, limit?, after?})` 只发现当前调用 Conversation 和回答 Agent 的关系。
`state` 默认 `active`，也可为 `closed` 或 `all`；`limit` 为 1–100，默认 50。
UUID 游标通过 `next_after` 返回。结果公开端点地址，不公开对端历史。

## SDK

Ruby：`client.workspace(workspace_id).conversation(conversation_id).links`。
TypeScript：`client.workspace(workspaceId).conversation(conversationId).links`。
Rust：`client.workspace(workspace_id)?.conversation(conversation_id)?.links()`。
三者均支持列出、创建、读取和关闭；创建回执保留重放标记，分页暴露 `items` 和 `next_after`。
完整的三语言代码见[英文 SDK 示例](../../../reference/agent-api/conversation-links.md#sdk-bindings)。

发送和请求工作仍通过捕获的内核工具目录或绑定 claim 的 Task operation 完成。
成员凭据不会冒充某个 Conversation 的回答 Agent。

## 恢复原结果

保存接受回执的 `input_public_id`，对于 request 还要保存 `completion` 的 Run UUID 和 Task key。
读取该 Task 恢复正式结果。有限 await 超时只结束该次等待，不取消已接受工作；之后读取同一 completion
仍可得到原结果。

有目标 Conversation 读取权限时，Ruby 的 `input_execution`、TypeScript 的 `inputExecution` 和
Rust 的 `InputExecution::new` 沿原 Input 的 materialization 与内核 fallback 链恢复。
它们不改读当前会话头或后来的手工 regeneration。单独的 materialization 缺失无法区分等待、
丢弃或不可用历史；在权威证据到来前保持结果未知，不自动重新发送或创建 request。

通信 Input 暴露 `communication_kind`、`link_public_id`、`requested_delivery_mode`、
`on_target_end` 和 `fallback_reason`。消费后的 Turn 保留通信与发送来源标记。
Callback 保留原 Input/Turn/Variant 身份，以及服务端提供时的原 Run UUID 和终态。
开始前取消可使 completion 结构化结果中的 Turn/Variant/Run UUID 为 null，不凭空创建执行。
