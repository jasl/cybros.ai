class Admin::UsersController < Admin::BaseController
  PAGE_SIZE = 25

  def index
    @members_pagy, @users = pagy(
      :offset,
      Current.account.users.members.includes(:identity).order_by_display_name,
      limit: PAGE_SIZE
    )
  end

  def show
    @member = Current.account.users.members.find_by!(public_id: params[:id])
  end

  def new
  end

  # Mail-less onboarding: the admin conveys the temporary password out of band; an
  # email held by an open Invitation needs explicit revocation first.
  def create
    submitted = params.expect(user: [:display_name, :email, :role, :password, :password_confirmation])
    role = submitted[:role].to_s.presence_in(User::Role::ASSIGNABLE_ROLES)

    if role.nil?
      flash.now[:alert] = t("admin.users.invalid_role")
      render :new, status: :unprocessable_entity
    elsif Invitation.exists?(email: Identity.normalize_value_for(:email, submitted[:email].to_s))
      flash.now[:alert] = t("admin.users.invitation_already_exists")
      render :new, status: :unprocessable_entity
    else
      creation = Current.account.create_direct_member(
        display_name: submitted[:display_name],
        email: submitted[:email].to_s,
        role: role,
        password: submitted[:password].to_s,
        password_confirmation: submitted[:password_confirmation].to_s
      )

      if creation.outcome == :created
        redirect_to admin_user_path(creation.member), notice: t("admin.users.created")
      else
        @creation_errors = creation.errors
        render :new, status: :unprocessable_entity
      end
    end
  end
end
