//! Wire types. Identifiers and timestamps remain strings; money remains decimal text.
use serde::{Deserialize, Serialize};
pub type JsonObject = serde_json::Map<String, serde_json::Value>;

/// A nullable request field: omitted, explicitly null, or a value.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub enum Field<T> {
    #[default]
    Unset,
    Null,
    Value(T),
}
impl<T> Field<T> {
    pub fn is_unset(&self) -> bool {
        matches!(self, Self::Unset)
    }
}
impl<T> From<T> for Field<T> {
    fn from(value: T) -> Self {
        Self::Value(value)
    }
}
impl<T: Serialize> Serialize for Field<T> {
    fn serialize<S: serde::Serializer>(&self, s: S) -> std::result::Result<S::Ok, S::Error> {
        match self {
            Self::Value(v) => v.serialize(s),
            Self::Null => s.serialize_none(),
            Self::Unset => Err(serde::ser::Error::custom("unset field must be omitted")),
        }
    }
}
impl<'de, T: Deserialize<'de>> Deserialize<'de> for Field<T> {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> std::result::Result<Self, D::Error> {
        Option::<T>::deserialize(d).map(|v| v.map_or(Self::Null, Self::Value))
    }
}

/// Unknown response vocabulary is preserved without accepting it in closed requests.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct ResponseName(pub String);

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Page<T> {
    pub items: Vec<T>,
    pub next_after: Option<String>,
}
#[derive(Clone, Debug, Serialize, Deserialize, Default)]
pub struct Empty {}

pub mod member;
pub mod platform;
pub mod requests;
pub use requests::*;
pub mod names;
