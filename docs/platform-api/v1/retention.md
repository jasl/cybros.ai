# Account execution-detail retention

```http
GET /api/v1/admin/account/retention
PATCH /api/v1/admin/account/retention
```

GET reads the Account's policy; PATCH changes it. Both require a live Human
owner or administrator through a Platform credential or API Session. The normal
Platform family's safe-cookie-read rule applies. Agent and executor credentials
cannot use this resource.

The default is 90 days. A positive whole number enables collection; `null`
disables it. The policy applies to eligible finished execution details, not to
conversation messages. Conversation text and history search remain available.
Increasing the period or disabling collection cannot restore details already
removed. Collection runs asynchronously through the existing scheduled jobs.

```json
{
  "account": {
    "execution_details_retention_days": 180
  }
}
```

PATCH accepts the same envelope. Send `null` explicitly to disable cleanup.
Unknown fields are ignored. Updates replace the current setting without a
client version or an idempotency key; they return the accepted value.

Both operations return `200` with the envelope above. Authentication failures
are `401`; a non-administrator Human API Session receives
`403 administrator_required`. A missing required `account` root is
`400 parameter_missing`. Invalid nonpositive, fractional or nonnumeric values
receive `422 validation_failed` without changing the setting. JSON null and an
empty form field use Rails' nullable integer casting.

The Human settings page is `/admin/retention`. SDK callers use
`PlatformClient#retention.fetch` and
`retention.update(execution_details_retention_days: days_or_nil)`.
`cmctl account retention` reads; `cmctl account retention DAYS` updates;
`cmctl account retention off` disables collection.
