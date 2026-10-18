use super::*;
use types::member::*;

impl Client {
    pub fn work(&self) -> WorkQueries {
        WorkQueries(self.0.clone())
    }
}

handle!(WorkQueries);
impl WorkQueries {
    query_get!(
        analysis,
        "work_analysis",
        WorkAnalysisQuery,
        WorkAnalysis,
        Some("analysis")
    );
    list!(runs, "runs", CrossWorkspaceRunQuery, Run, "runs");
    list!(
        attention,
        "attention",
        AttentionQuery,
        AttentionItem,
        "items"
    );
    query_get!(
        report,
        "work_report",
        WorkReportQuery,
        WorkReport,
        Some("report")
    );
}

handle!(GlobalSchedules);
impl GlobalSchedules {
    list!(list, "", GlobalScheduleQuery, Schedule, "schedules");
}
