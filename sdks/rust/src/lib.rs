//! Async clients for the Member, Executor, and Human Platform planes of Nexus.
//!
//! Resource handles perform no IO until an operation is awaited. The application
//! owns persistence, idempotency keys, local execution, and shutdown.
pub mod authoring;
pub mod checkpoints;
pub mod credentials;
pub mod error;
pub mod events;
pub mod execution;
pub mod oauth;
#[cfg(feature = "realtime")]
pub mod realtime;
pub mod resources;
pub mod thread;
pub mod transport;
pub mod types;
pub use error::{Error, Result};
pub use resources::{Client, ExecutorClient, PlatformClient};
pub use transport::{ClientOptions, Response};
pub use types::Field;
