use super::*;
use types::member::*;
handle!(Runs);
impl Runs {
    list!(list, "", RunListQuery, Run, "runs");
    create!(create, "", CreateRun, Some("run"), CreatedRun, None);
    pub fn run(&self, id: &str) -> Result<RunContext> {
        Ok(RunContext(self.0.id(id)?))
    }
}
handle!(RunContext);
impl RunContext {
    get!(fetch, "", Run, Some("run"));
    command!(delete, DELETE, "", Empty, None);
    command!(start, POST, "start", Run, Some("run"));
    command!(resume, POST, "resume", Run, Some("run"));
    write!(pause, POST, "pause", RunControl, None, Run, Some("run"));
    write!(stop, POST, "stop", RunControl, None, Run, Some("run"));
    write!(
        set_default_runner,
        PUT,
        "default_runner",
        SetDefaultRunner,
        Some("default_runner"),
        Run,
        Some("run")
    );
    create!(
        append,
        "tasks",
        AppendTasks,
        None,
        AppendedTasks,
        Some("receipt")
    );
    query_get!(events, "events", EventQuery, EventPage, None);
    query_get!(
        transcript,
        "transcript",
        TranscriptQuery,
        RunTranscript,
        None
    );
    get!(graph, "graph", RunGraph, None);
    get!(phases, "phases", RunPhases, None);
    child!(inputs, "inputs", Inputs);
    child_id!(task, "tasks", TaskContext);
}
handle!(TaskContext);
impl TaskContext {
    get!(realtime, "realtime", TaskRealtime, Some("realtime"));
    write!(
        answer_realtime,
        PUT,
        "realtime",
        RealtimeSignal,
        None,
        TaskRealtime,
        Some("realtime")
    );
    get!(fetch, "", TaskDetail, Some("task"));
    get!(request, "request", SealedRequest, Some("request"));
    write!(
        resolve,
        POST,
        "resolution",
        ResolveTask,
        None,
        Task,
        Some("task")
    );
    write!(retry, POST, "retry", RetryTask, None, Task, Some("task"));
    command!(abandon, POST, "abandon", Task, Some("task"));
    command!(cancel, POST, "cancel", Task, Some("task"));
    command!(approve, POST, "approve", Task, Some("task"));
    write!(deny, POST, "deny", DenyTask, None, Task, Some("task"));
    command!(compact, POST, "compact", CompactedRound, None);
}
handle!(InferenceRequests);
impl InferenceRequests {
    list!(
        list,
        "",
        InferenceListQuery,
        InferenceRequestSummary,
        "inference_requests"
    );
    create!(
        create,
        "",
        CreateInferenceRequest,
        Some("inference_request"),
        InferenceRequest,
        Some("inference_request")
    );
    write!(
        estimate_input,
        POST,
        "input_estimate",
        InferenceEstimate,
        Some("input_estimate"),
        InferenceRequestInputEstimate,
        Some("input_estimate")
    );
    pub fn inference_request(&self, id: &str) -> Result<InferenceRequestContext> {
        Ok(InferenceRequestContext(self.0.id(id)?))
    }
}
handle!(InferenceRequestContext);
impl InferenceRequestContext {
    get!(fetch, "", InferenceRequest, Some("inference_request"));
    command!(
        cancel,
        POST,
        "cancellation",
        InferenceRequest,
        Some("inference_request")
    );
    command!(delete, DELETE, "", Empty, None);
    query_get!(
        events,
        "events",
        EventQuery,
        InferenceRequestEventPage,
        None
    );
    pub async fn download(&self, index: u32) -> Result<Download> {
        self.0
            .transport
            .download(
                &format!("{}/files/{index}", self.0.path),
                None::<&()>,
                Headers::default(),
            )
            .await
    }
}
