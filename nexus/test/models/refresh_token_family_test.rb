require "test_helper"

class RefreshTokenFamilyTest < ActiveSupport::TestCase
  setup do
    @member = create_agent_member(display_name: "Family owner", agent_identifier: "install-family-owner")
    @executor = @member.task_executors.create!(
      account: @member.account,
      executor_kind: :agent_application,
      display_name: "Family executor"
    )
  end

  test "one family revocation fact immediately fences access and refresh credentials" do
    family = build_family
    access = build_access(family)
    refresh = build_refresh(family, access)

    assert access.executor_usable?
    assert_predicate refresh, :current?
    assert_predicate family, :rotation_acceptable?

    family.revoke

    assert family.reload.revoked?
    assert_nil access.reload.revoked_at, "per-row markers converge separately"
    assert_nil refresh.reload.revoked_at, "per-row markers converge separately"
    assert_not access.executor_usable?
    assert_predicate refresh, :current?
    assert_not_predicate family, :rotation_acceptable?
  end

  test "rotation acceptance reads every mutable authority fence from the family" do
    family = build_family
    refresh = build_refresh(family, build_access(family))

    assert_predicate refresh, :current?
    assert_predicate family, :rotation_acceptable?

    advance_credential_epoch(@executor)

    assert_predicate refresh.reload, :current?
    assert_not_predicate family.reload, :rotation_acceptable?
  end

  test "Agent removal fences a bound family before credential markers run" do
    family = build_family
    refresh = build_refresh(family, build_access(family))

    @member.remove

    assert_not family.reload.rotation_acceptable?
    assert_predicate refresh.reload, :current?
  end

  test "an executor epoch can never be issued a second lineage" do
    build_family.revoke
    duplicate = RefreshTokenFamily.new(family_attributes)

    assert_not duplicate.valid?
    assert duplicate.errors.of_kind?(:credential_epoch, :taken)
    assert_raises ActiveRecord::RecordNotUnique do
      duplicate.save!(validate: false)
    end
  end

  private

    def build_family
      RefreshTokenFamily.create!(family_attributes)
    end

    def family_attributes
      {
        account: @member.account,
        user: @member,
        access_token_name: "Device pairing",
        task_executor: @executor,
        credential_epoch: @executor.credential_epoch,
        user_authority_generation: @member.authority_generation,
        last_used_at: Time.current,
      }
    end

    def build_access(family)
      parts = AccessToken::DIGESTED.mint_parts
      @member.access_tokens.create!(
        credential_plane: :executor_transport,
        refresh_token_family: family,
        name: family.access_token_name,
        source: :oauth_device,
        lookup_id: parts.lookup_id,
        secret_digest: parts.digest,
        expires_at: AccessToken::OAUTH_TTL.from_now,
        task_executor: @executor,
        credential_epoch: @executor.credential_epoch,
        user_authority_generation: @member.authority_generation
      )
    end

    def build_refresh(family, access)
      parts = RefreshToken::DIGESTED.mint_parts
      family.refresh_tokens.create!(
        account: @member.account,
        user: @member,
        access_token: access,
        lookup_id: parts.lookup_id,
        secret_digest: parts.digest
      )
    end
end
