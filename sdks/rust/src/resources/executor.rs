use super::*;
use types::member::*;
impl ExecutorClient {
    get!(executor, "", ExecutorDescription, None);
    write!(
        announce,
        PUT,
        "announcement", Announcement, None, ExecutorDescription, None
    );
    write!(
        report_progress,
        POST,
        "progress", ProgressRequest, None, Empty, None
    );
    query_get!(inbox, "inbox", PageQuery, Vec<InboxTask>, Some("tasks"));
    pub async fn upload(&self, body: UploadBody) -> Result<Response<Upload>> {
        self.0
            .transport
            .upload(&format!("{}/uploads", self.0.path), body)
            .await
    }
    pub fn inbox_task(&self, run_public_id: &str, task_key: &str) -> Result<ExecutorTask> {
        Ok(ExecutorTask(
            self.0.child("inbox").id(run_public_id)?.id(task_key)?,
        ))
    }
}
handle!(ExecutorTask);
impl ExecutorTask {
    command!(claim, POST, "claim", ClaimedTask, None);
    pub async fn claim_status(&self, claim_token: &str) -> Result<Response<ClaimStatus>> {
        self.0
            .call(
                Method::GET,
                "claim",
                None::<&()>,
                None::<&()>,
                None,
                Headers {
                    claim_token: Some(claim_token),
                    ..Default::default()
                },
                Some("claim"),
            )
            .await
    }
    pub async fn realtime(&self, claim_token: &str) -> Result<Response<TaskRealtime>> {
        self.0
            .call(
                Method::GET,
                "realtime",
                None::<&()>,
                None::<&()>,
                None,
                Headers {
                    claim_token: Some(claim_token),
                    ..Default::default()
                },
                Some("realtime"),
            )
            .await
    }
    pub async fn offer_realtime(
        &self,
        claim_token: &str,
        signal: &RealtimeOffer,
    ) -> Result<Response<TaskRealtime>> {
        self.0
            .call(
                Method::PUT,
                "realtime",
                None::<&()>,
                Some(signal),
                None,
                Headers {
                    claim_token: Some(claim_token),
                    ..Default::default()
                },
                Some("realtime"),
            )
            .await
    }
    write!(extend, POST, "extend", ExtendClaim, None, ClaimedTask, None);
    write!(commit, POST, "commit", CommitTask, None, Task, Some("task"));
    write!(
        submit,
        POST,
        "operations",
        SubmitOperation,
        None,
        OperationEvent,
        Some("operation")
    );
    write!(
        observe,
        POST,
        "observation", ObserveOperation, None, OperationRead, None
    );
    pub async fn operations(
        &self,
        claim_token: &str,
        query: &OperationQuery,
    ) -> Result<Response<TaskOperations>> {
        self.0
            .call(
                Method::GET,
                "operations",
                Some(query),
                None::<&()>,
                None,
                Headers {
                    claim_token: Some(claim_token),
                    ..Default::default()
                },
                Some("operations"),
            )
            .await
    }
    pub async fn attachment(&self, public_id: &str, claim_token: &str) -> Result<Response<Upload>> {
        self.0
            .child("attachments")
            .id(public_id)?
            .call(
                Method::GET,
                "",
                None::<&()>,
                None::<&()>,
                None,
                Headers {
                    claim_token: Some(claim_token),
                    ..Default::default()
                },
                Some("upload"),
            )
            .await
    }
    pub async fn attachment_bytes(
        &self,
        public_id: &str,
        claim_token: &str,
        range: Option<&str>,
    ) -> Result<Download> {
        let resource = self.0.child("attachments").id(public_id)?.child("bytes");
        resource
            .transport
            .download(
                &resource.path,
                None::<&()>,
                Headers {
                    claim_token: Some(claim_token),
                    range,
                    ..Default::default()
                },
            )
            .await
    }
}
