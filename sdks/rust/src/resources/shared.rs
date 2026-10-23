use super::*;
use types::member::*;
handle!(Memory);
impl Memory {
    query_get!(
        bindings,
        "",
        MemoryListQuery,
        MemoryBindings,
        Some("memory_context")
    );
    query_get!(
        list,
        "",
        MemoryListQuery,
        Vec<MemoryDocument>,
        Some("memory")
    );
    write!(
        read,
        POST,
        "show",
        MemoryRead,
        Some("memory"),
        MemoryDocument,
        Some("memory")
    );
    write!(
        write,
        POST,
        "",
        MemoryWrite,
        Some("memory"),
        MemoryDocument,
        Some("memory")
    );
    write!(
        edit,
        POST,
        "edit",
        MemoryEdit,
        Some("memory"),
        MemoryDocument,
        Some("memory")
    );
    write!(
        delete,
        POST,
        "delete",
        MemoryDelete,
        Some("memory"),
        Empty,
        None
    );
    write!(
        grep,
        POST,
        "grep",
        MemoryGrep,
        Some("memory"),
        MemoryMatches,
        None
    );
}
handle!(MemoryCollections);
impl MemoryCollections {
    list!(list, "", PageQuery, MemoryCollection, "memory_collections");
    pub fn collection(&self, public_id: &str) -> Result<MemoryCollectionContext> {
        Ok(MemoryCollectionContext(self.0.id(public_id)?))
    }
}
handle!(OwnedMemoryCollections);
impl OwnedMemoryCollections {
    list!(
        list,
        "",
        OwnedMemoryCollectionQuery,
        MemoryCollection,
        "memory_collections"
    );
    write!(
        create,
        POST,
        "",
        CreateMemoryCollection,
        Some("memory_collection"),
        MemoryCollection,
        Some("memory_collection")
    );
}
handle!(MemoryCollectionContext);
impl MemoryCollectionContext {
    get!(fetch, "", MemoryCollection, Some("memory_collection"));
    write!(
        update,
        PATCH,
        "",
        UpdateMemoryCollection,
        Some("memory_collection"),
        MemoryCollection,
        Some("memory_collection")
    );
    write!(
        archive,
        POST,
        "archive",
        MemoryCollectionVersion,
        Some("memory_collection"),
        MemoryCollection,
        Some("memory_collection")
    );
    write!(
        restore,
        POST,
        "restore",
        MemoryCollectionVersion,
        Some("memory_collection"),
        MemoryCollection,
        Some("memory_collection")
    );
    write!(
        delete,
        DELETE,
        "",
        MemoryCollectionVersion,
        Some("memory_collection"),
        Empty,
        None
    );
    child!(documents, "documents", MemoryDocuments);
}
handle!(MemoryDocuments);
impl MemoryDocuments {
    get!(list, "", Vec<MemoryDocument>, Some("memory"));
    write!(
        read,
        POST,
        "show",
        MemoryRead,
        Some("memory"),
        MemoryDocument,
        Some("memory")
    );
    write!(
        write,
        POST,
        "",
        CollectionMemoryWrite,
        Some("memory"),
        MemoryDocument,
        Some("memory")
    );
    write!(
        edit,
        POST,
        "edit",
        CollectionMemoryEdit,
        Some("memory"),
        MemoryDocument,
        Some("memory")
    );
    write!(
        delete,
        POST,
        "delete",
        CollectionMemoryDelete,
        Some("memory"),
        Empty,
        None
    );
    write!(
        grep,
        POST,
        "grep",
        MemoryGrep,
        Some("memory"),
        MemoryMatches,
        None
    );
}
handle!(StoreEntries);
impl StoreEntries {
    list!(list, "", PageQuery, StoreEntrySummary, "store_entries");
    create!(
        create,
        "",
        CreateStoreEntry,
        Some("store_entry"),
        StoreEntry,
        Some("store_entry")
    );
    pub fn entry(&self, public_id: &str) -> Result<StoreEntryContext> {
        Ok(StoreEntryContext(self.0.id(public_id)?))
    }
}
handle!(StoreEntryContext);
impl StoreEntryContext {
    get!(fetch, "", StoreEntry, Some("store_entry"));
    write!(
        update,
        PATCH,
        "",
        UpdateStoreEntry,
        Some("store_entry"),
        StoreEntry,
        Some("store_entry")
    );
    pub async fn delete(&self, lock_version: i64) -> Result<Response<Empty>> {
        self.0
            .call(
                Method::DELETE,
                "",
                Some(&[("lock_version", lock_version)]),
                None::<&()>,
                None,
                Headers::default(),
                None,
            )
            .await
    }
}
handle!(PromptDocuments);
impl PromptDocuments {
    get!(list, "", Vec<PromptDocument>, Some("prompt_documents"));
    pub fn document(&self, slot: &str) -> Result<PromptDocumentContext> {
        Ok(PromptDocumentContext(self.0.id(slot)?))
    }
}
handle!(PromptDocumentContext);
impl PromptDocumentContext {
    get!(fetch, "", PromptDocument, Some("prompt_document"));
    write!(
        write,
        PUT,
        "",
        WritePromptDocument,
        Some("prompt_document"),
        PromptDocument,
        Some("prompt_document")
    );
    command!(delete, DELETE, "", Empty, None);
}
handle!(Uploads);
impl Uploads {
    pub async fn create(&self, body: UploadBody) -> Result<Response<Upload>> {
        self.0.transport.upload(&self.0.path, body).await
    }
    pub fn upload(&self, public_id: &str) -> Result<UploadContext> {
        Ok(UploadContext(self.0.id(public_id)?))
    }
}
handle!(UploadContext);
impl UploadContext {
    get!(fetch, "", Upload, Some("upload"));
    pub async fn bytes(&self, range: Option<&str>, etag: Option<&str>) -> Result<Download> {
        self.0
            .transport
            .download(
                &format!("{}/bytes", self.0.path),
                None::<&()>,
                Headers {
                    range,
                    etag,
                    ..Default::default()
                },
            )
            .await
    }
    pub async fn thumbnail(&self, etag: Option<&str>) -> Result<Download> {
        self.image("thumbnail", etag).await
    }
    pub async fn preview(&self, etag: Option<&str>) -> Result<Download> {
        self.image("preview", etag).await
    }
    async fn image(&self, kind: &str, etag: Option<&str>) -> Result<Download> {
        self.0
            .transport
            .download(
                &format!("{}/{kind}", self.0.path),
                None::<&()>,
                Headers {
                    etag,
                    ..Default::default()
                },
            )
            .await
    }
}
