// External-service fixture only. rho uses its shipped native RPC client;
// Nexus owns every task, question, store entry and retained capture.
const [announcement, worktree] = process.argv.slice(2);
const calls = [];
let projection;
let sequence = 0;

function request(kind, id) {
  projection.runtimeRequests = [{ id, nodeId: `${id}-node`, kind, status: "pending",
    responseCapability: { type: "live", providerSessionId: "native-session" } }];
  projection.providerSessions = [{ id: "native-session", status: "waiting", cwd: worktree }];
  projection.nodes = [{ id: `${id}-node`, parentNodeId: "check-node" }];
  projection.turnItems = kind === "user_input"
    ? [{ type: "user_input_request", requestId: id, questions: [{ id: "color", question: "Which color should the marker use?", options: [] }] }]
    : [{ type: "approval_request", requestId: id, prompt: "Run the fixture checks?" },
      { type: "command_execution", id: "check", nodeId: "check-node", input: "ruby test.rb" }];
}

function rpc(method, params) {
  calls.push({ method, params });
  switch (method) {
    case "server.getConfig":
      return { environment: { orchestrationProtocolVersion: 2 }, providers: [{
        instanceId: "fixture-provider", driver: "codex", enabled: true, installed: true,
        status: "ready", auth: { status: "unknown" }, models: [
          { slug: "fixture-model", name: "Fixture Coding Model", isDefault: true, isCustom: false, capabilities: null },
        ],
      }] };
    case "orchestration.launchThread":
      if (projection) throw new Error("duplicate launch");
      projection = {
        thread: { id: params.threadId, projectId: params.projectId, worktreePath: worktree,
          branch: "fixture-branch", modelSelection: params.modelSelection, runtimeMode: params.runtimeMode },
        runs: [{ id: "native-run-1", ordinal: 1, status: "running", modelSelection: params.modelSelection }],
        messages: [{ id: params.initialMessage.messageId, role: "user", text: params.initialMessage.text }],
        turnItems: [], runtimeRequests: [], providerSessions: [], nodes: [],
        subagents: [{ id: "native-worker", status: "running" }],
      };
      request("user_input", "choose-color");
      return { threadId: params.threadId, projection, resumed: false };
    case "orchestration.getThreadProjection":
      if (params.threadId !== projection?.thread.id) throw new Error("unknown thread");
      return projection;
    case "orchestration.dispatchCommand":
      if (params.threadId !== projection?.thread.id) throw new Error("wrong thread");
      switch (params.type) {
        case "runtime-request.respond":
          if (params.requestId === "choose-color") {
            if (params.answers.color !== "blue") throw new Error("wrong ordinary answer");
            request("command", "approve-check");
          } else {
            if (params.requestId !== "approve-check" || params.decision !== "accept") throw new Error("wrong approval");
            projection.runtimeRequests = [];
            projection.runs.at(-1).status = "completed";
            projection.messages.push({ id: "native-answer", role: "assistant", text: "Implemented the blue marker and checked it." });
            projection.turnItems = [{ type: "command_execution", id: "check", nodeId: "check-node",
              input: "ruby test.rb", exitCode: 0, outputOmitted: true }];
          }
          break;
        case "message.dispatch":
          projection.messages.push({ id: params.messageId, role: "user", text: params.text });
          if (params.dispatchMode.type === "steer_active") {
            if (params.dispatchMode.targetRunId !== projection.runs.at(-1).id) throw new Error("wrong steer target");
          } else if (params.dispatchMode.type === "start_immediately") {
            const ordinal = projection.runs.length + 1;
            projection.runs.push({ id: `native-run-${ordinal}`, ordinal, status: "running", modelSelection: projection.thread.modelSelection });
            projection.subagents = [{ id: `native-worker-${ordinal}`, status: "running" }];
            request("user_input", `confirm-continuation-${ordinal}`);
          } else {
            throw new Error("unexpected dispatch mode");
          }
          break;
        case "run.interrupt":
          if (params.runId !== projection.runs.at(-1).id || params.holdQueue !== true) throw new Error("wrong native stop");
          projection.runs.at(-1).status = "interrupted";
          projection.subagents.forEach((worker) => { worker.status = "cancelled"; });
          projection.runtimeRequests = [];
          break;
        default: throw new Error(`unexpected command ${params.type}`);
      }
      return { sequence: ++sequence };
    case "orchestration.getFullThreadDiff":
      return { diff: "diff --git a/marker.txt b/marker.txt\n+blue marker\n" };
    case "orchestration.getTurnItem":
      return { item: { type: "command_execution", input: "ruby test.rb", output: "1 check passed", exitCode: 0, outputOmitted: false } };
    default: throw new Error(`unexpected RPC ${method}`);
  }
}

const server = Bun.serve({
  hostname: "127.0.0.1", port: 0,
  fetch(req, server) {
    const url = new URL(req.url);
    if (url.pathname === "/fixture") return Response.json({ calls, projection });
    if (url.pathname === "/fixture/settle-workers" && req.method === "POST") {
      projection.subagents.forEach((worker) => { worker.status = "completed"; });
      return Response.json({ settled: true });
    }
    if (url.pathname === "/api/auth/websocket-ticket" && req.method === "POST") {
      if (req.headers.get("authorization") !== "Bearer fixture-t3-bearer") return new Response("unauthorized", { status: 401 });
      return Response.json({ ticket: "fixture-ticket", expiresAt: "2030-01-01T00:00:00.000Z" });
    }
    if (url.pathname === "/ws" && url.searchParams.get("wsTicket") === "fixture-ticket" &&
        url.searchParams.get("orchestrationProtocol") === "2" && server.upgrade(req)) return;
    return new Response("unknown endpoint", { status: 404 });
  },
  websocket: {
    message(socket, text) {
      const parsed = JSON.parse(text);
      for (const frame of Array.isArray(parsed) ? parsed : [parsed]) {
        if (frame._tag === "Ping") socket.send(JSON.stringify({ _tag: "Pong" }));
        if (frame._tag !== "Request") continue;
        const value = rpc(frame.tag, frame.payload);
        socket.send(JSON.stringify({ _tag: "Exit", requestId: frame.id, exit: { _tag: "Success", value } }));
      }
    },
  },
});
await Bun.write(announcement, server.url.origin);
