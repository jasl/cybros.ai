module RefreshTokens
  # The credential material produced both when a device connection is consumed
  # and when its refresh lineage rotates. It carries no outcome or lifecycle.
  Bundle = Data.define(
    :access_token,
    :executor_access_token,
    :refresh_token,
    :access_secret,
    :executor_access_secret,
    :refresh_secret
  )
end
