# THE SESSION DOOR FOR BYTES: the signed-in Human's browser posts
# multipart here and reads back the descriptor the member plane's `POST
# /agent_api/v1/uploads` answers. ONE ingest — `UploadIngest`,
# `ContentUploads::Create` behind it, Marcel on the bytes, the size bound
# at the door — behind three authenticated doors (the executor plane's
# captures are the third); the framework's anonymous direct-upload
# endpoints stay undrawn (`draw_routes = false`), because a direct upload
# creates the blob from the CLIENT'S declared type and size against the
# written contract that the bytes decide. The creator is the session's
# user, so an input of theirs later names the upload creator-scoped
# exactly as the member door's would. JSON out, every status the member
# door speaks; the session plane's own refusal of a signed-out caller is
# the sign-in redirect, as on every console door.
class UploadsController < ApplicationController
  include APIErrors
  include UploadIngest

  def create
    ingest_upload(account: Current.account, creator: Current.user)
  end
end
