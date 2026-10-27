//! Step authoring values. Nexus owns execution, ordering, edges, and barriers.
use crate::{
    Error, Result,
    types::{
        JsonObject,
        requests::{
            McpToolImport, ModelRequest, ModelSelection, ToolDeclaration, ToolRoute, Workload,
        },
    },
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::BTreeMap;

macro_rules! leaf {
    ($name:ident {$($required:ident:$rty:ty),*} {$($optional:ident:$oty:ty),*})=>{
        #[derive(Clone,Debug,Default,Serialize,Deserialize)]
        pub struct $name {
            $(pub $required:$rty,)*
            #[serde(skip_serializing_if="Option::is_none")] pub key:Option<String>,
            #[serde(skip_serializing_if="Option::is_none")] pub detached:Option<bool>,
            #[serde(skip_serializing_if="Option::is_none")] pub lifetime:Option<Lifetime>,
            #[serde(skip_serializing_if="Option::is_none")] pub wake:Option<Wake>,
            #[serde(skip_serializing_if="Option::is_none")] pub on_failure:Option<OnFailure>,
            #[serde(skip_serializing_if="Option::is_none")] pub visibility:Option<Visibility>,
            #[serde(skip_serializing_if="Option::is_none")] pub after:Option<Vec<String>>,
            $(#[serde(skip_serializing_if="Option::is_none")] pub $optional:Option<$oty>,)*
        }
    };
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Lifetime {
    Turn,
    Conversation,
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Wake {
    Auto,
    Passive,
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OnFailure {
    Halt,
    Propagate,
    Absorb,
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Visibility {
    Visible,
    Collapsed,
    Hidden,
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Losers {
    Cancel,
    RunOut,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(untagged)]
pub enum Until {
    Named(UntilName),
    Quorum(u32),
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum UntilName {
    All,
    Any,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(untagged)]
pub enum AuthoringModel {
    Reference(String),
    Selector(ModelRequest),
}
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct ModelDefaults {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub executor_contexts: Option<JsonObject>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub workload: Option<Workload>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tools: Option<Vec<ToolDeclaration>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub kernel_tools: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub runner_executor_public_ids: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub runner_tool_names: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mcp_tools: Option<Vec<McpToolImport>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model_selection: Option<ModelSelection>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fallback_models: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model: Option<AuthoringModel>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub configuration: Option<JsonObject>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub instructions: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub compaction: Option<JsonObject>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub on_failure: Option<OnFailure>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fan_on_failure: Option<FanOnFailure>,
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FanOnFailure {
    Absorb,
    Propagate,
}
leaf!(ToolStep {name:String,input:JsonObject} {executor_context:JsonObject,timeout_ms:u64,model_defaults:Box<ModelDefaults>,route:ToolRoute});
leaf!(ModelStep {prompt:String} {executor_contexts:JsonObject,model:AuthoringModel,workload:Workload,tools:Vec<ToolDeclaration>,instructions:String,configuration:JsonObject,compaction:JsonObject,fan_on_failure:FanOnFailure,results:Vec<String>,attachments:Vec<String>,kernel_tools:Vec<String>,runner_executor_public_ids:Vec<String>,runner_tool_names:Vec<String>,mcp_tools:Vec<McpToolImport>,model_selection:ModelSelection,fallback_models:Vec<String>});
leaf!(AskStep {prompt:String} {options:Vec<String>,multi:bool,fields:Vec<serde_json::Value>,timeout_ms:u64,indefinite:bool});
leaf!(WaitStep {task:String} {run_public_id:String,timeout_ms:u64});
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct ParallelStep {
    pub parallel: Vec<Step>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub until: Option<Until>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub losers: Option<Losers>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub key: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub on_failure: Option<OnFailure>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub lifetime: Option<Lifetime>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub wake: Option<Wake>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(untagged)]
pub enum Step {
    Tool { tool: ToolStep },
    Model { model: Box<ModelStep> },
    Ask { ask: AskStep },
    Wait { wait: WaitStep },
    Parallel(ParallelStep),
    Sequence(Vec<Step>),
}
impl Step {
    pub fn tool(name: impl Into<String>, input: JsonObject) -> Self {
        Self::Tool {
            tool: ToolStep {
                name: name.into(),
                input,
                ..Default::default()
            },
        }
    }
    pub fn model(prompt: impl Into<String>) -> Self {
        Self::Model {
            model: Box::new(ModelStep {
                prompt: prompt.into(),
                ..Default::default()
            }),
        }
    }
    pub fn ask(prompt: impl Into<String>) -> Self {
        Self::Ask {
            ask: AskStep {
                prompt: prompt.into(),
                ..Default::default()
            },
        }
    }
    pub fn wait(task: impl Into<String>) -> Self {
        Self::Wait {
            wait: WaitStep {
                task: task.into(),
                ..Default::default()
            },
        }
    }
    pub fn parallel(members: Vec<Step>) -> Self {
        Self::Parallel(ParallelStep {
            parallel: members,
            ..Default::default()
        })
    }
}
#[derive(Clone, Debug, Default)]
pub struct Steps {
    steps: Vec<Step>,
}
impl Steps {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn push(&mut self, step: Step) -> &mut Self {
        self.steps.push(step);
        self
    }
    pub fn build(self) -> Vec<Step> {
        self.steps
    }
}
/// Catalog-backed declarations retain the deployment's canonical text and schema.
#[derive(Clone, Debug)]
pub struct Toolsets {
    tools: BTreeMap<String, crate::types::member::KernelTool>,
}
impl Toolsets {
    pub fn from_catalog(tools: Vec<crate::types::member::KernelTool>) -> Self {
        Self {
            tools: tools
                .into_iter()
                .map(|t| (t.canonical_name.clone(), t))
                .collect(),
        }
    }
    pub fn definitions_for(&self, names: &[&str]) -> Result<Vec<JsonObject>> {
        names
            .iter()
            .map(|name| {
                self.tools
                    .get(*name)
                    .or_else(|| self.tools.values().find(|t| t.name == *name))
                    .map(|t| t.definition.clone())
                    .ok_or(Error::Configuration(
                        "unknown kernel tool in this deployment",
                    ))
            })
            .collect()
    }
    pub fn alias(
        &self,
        name: &str,
        canonical: &str,
        params: Option<JsonObject>,
        omit: Option<Vec<String>>,
        description: Option<String>,
    ) -> Result<JsonObject> {
        if !self.tools.contains_key(canonical) {
            return Err(Error::Configuration("unknown canonical kernel tool"));
        }
        let mut alias = json!({"name":name,"canonical":canonical})
            .as_object()
            .cloned()
            .expect("literal object");
        if let Some(v) = params {
            alias.insert("params".into(), Value::Object(v));
        }
        if let Some(v) = omit {
            alias.insert("omit".into(), json!(v));
        }
        if let Some(v) = description {
            alias.insert("description".into(), json!(v));
        }
        Ok(alias)
    }
}

/// MCP metadata is additive. This conversion intentionally selects only name,
/// description and schema, and serializes fields in stable declaration order.
#[derive(Clone, Debug, Serialize)]
pub struct FunctionEntry {
    #[serde(rename = "type")]
    kind: &'static str,
    pub function: LoweredFunction,
}
#[derive(Clone, Debug, Serialize)]
pub struct LoweredFunction {
    pub name: String,
    pub description: String,
    pub parameters: JsonObject,
}
pub struct ToolLowering;
impl ToolLowering {
    pub fn function_entry(tool: &JsonObject) -> Result<FunctionEntry> {
        let name = tool
            .get("name")
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
            .ok_or(Error::Configuration("MCP tool name is required"))?;
        let schema = tool
            .get("inputSchema")
            .and_then(Value::as_object)
            .or_else(|| tool.get("input_schema").and_then(Value::as_object))
            .filter(|s| !s.is_empty())
            .cloned()
            .unwrap_or_else(|| {
                json!({"type":"object","properties":{}})
                    .as_object()
                    .cloned()
                    .expect("literal")
            });
        Ok(FunctionEntry {
            kind: "function",
            function: LoweredFunction {
                name: name.into(),
                description: tool
                    .get("description")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .into(),
                parameters: schema,
            },
        })
    }
    pub fn function_entries(tools: &[JsonObject]) -> Result<Vec<FunctionEntry>> {
        let mut entries = tools
            .iter()
            .map(Self::function_entry)
            .collect::<Result<Vec<_>>>()?;
        entries.sort_by(|a, b| a.function.name.cmp(&b.function.name));
        Ok(entries)
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Toolset {
    Orchestration,
    Conversation,
    History,
    Memory,
    Discovery,
    Skills,
    Images,
    Schedules,
}
impl Toolset {
    pub fn names(self) -> &'static [&'static str] {
        match self {
            Self::Orchestration => &[
                "nexus.graph.delegate_task",
                "nexus.graph.wait",
                "nexus.human.ask",
            ],
            Self::Conversation => &[
                "nexus.conversation.spawn",
                "nexus.conversation.send",
                "nexus.conversation.request",
                "nexus.conversation.links",
                "nexus.conversation.status",
                "nexus.conversation.cancel",
            ],
            Self::History => &["nexus.conversation.search", "nexus.conversation.read"],
            Self::Memory => &[
                "nexus.memory.read",
                "nexus.memory.write",
                "nexus.memory.edit",
                "nexus.memory.ls",
                "nexus.memory.grep",
                "nexus.memory.delete",
            ],
            Self::Discovery => &[
                "nexus.tools.search",
                "nexus.tools.call",
                "nexus.runners.list",
                "nexus.models.list",
            ],
            Self::Skills => &["nexus.skill.load"],
            Self::Images => &["nexus.image.generate"],
            Self::Schedules => &["nexus.schedules.read", "nexus.schedules.manage"],
        }
    }
}
impl Toolsets {
    pub fn names(groups: &[Toolset]) -> Vec<String> {
        let mut names = vec![];
        for group in groups {
            for name in group.names() {
                if !names.iter().any(|n| n == name) {
                    names.push((*name).to_owned());
                }
            }
        }
        names
    }
    pub fn verify(&self, groups: &[Toolset]) -> Result<Vec<String>> {
        let names = Self::names(groups);
        if names.iter().any(|name| !self.tools.contains_key(name)) {
            return Err(Error::Configuration(
                "requested kernel toolset is unavailable on this deployment",
            ));
        }
        Ok(names)
    }
}
