class SessionsController < Clearance::SessionsController
  include MfaExpiryMethods
  include WebauthnVerifiable

  before_action :redirect_to_signin, unless: :signed_in?, only: %i[verify authenticate]
  before_action :redirect_to_new_mfa, if: :mfa_required_not_yet_enabled?, only: %i[verify authenticate]
  before_action :redirect_to_settings_strong_mfa_required, if: :mfa_required_weak_level_enabled?, only: %i[verify authenticate]
  before_action :ensure_not_blocked, only: :create
  after_action :delete_mfa_session, only: %i[webauthn_create otp_create]

  def create
    @user = find_user

    if @user&.mfa_enabled?
      @otp_verification_url = otp_create_session_path
      setup_webauthn_authentication(form_url: webauthn_create_session_path)
      session[:mfa_user] = @user.id

      session[:mfa_login_started_at] = Time.now.utc.to_s
      create_new_mfa_expiry

      render "multifactor_auths/prompt"
    else
      do_login
    end
  end

  def webauthn_create
    @user = User.find(session[:mfa_user])

    unless session_active?
      login_failure(t("multifactor_auths.session_expired"))
      return
    end
    return login_failure(@webauthn_error) unless webauthn_credential_verified?

    record_mfa_login_duration(mfa_type: "webauthn")

    do_login
  end

  def otp_create
    @user = User.find(session[:mfa_user])

    if login_conditions_met?
      record_mfa_login_duration(mfa_type: "otp")

      do_login
    elsif !session_active?
      login_failure(t("multifactor_auths.session_expired"))
    else
      login_failure(t("multifactor_auths.incorrect_otp"))
    end
  end

  def verify
  end

  def authenticate
    if verify_user
      session[:verified_user] = current_user.id
      session[:verification]  = Time.current + Gemcutter::PASSWORD_VERIFICATION_EXPIRY
      redirect_to session.delete(:redirect_uri) || root_path
    else
      flash.now[:alert] = t("profiles.request_denied")
      render :verify, status: :unauthorized
    end
  end

  private

  def verify_user
    current_user.authenticated? verify_password_params[:password]
  end

  def verify_password_params
    params.require(:verify_password).permit(:password)
  end

  def do_login
    sign_in(@user) do |status|
      if status.success?
        StatsD.increment "login.success"
        set_login_flash
        redirect_back_or(url_after_create)
      else
        login_failure(status.failure_message)
      end
    end
  end

  def login_failure(message)
    StatsD.increment "login.failure"
    flash.now.notice = message
    render "sessions/new", status: :unauthorized
  end

  def session_params
    params.require(:session)
  end

  def find_user
    password = session_params[:password].is_a?(String) && session_params.fetch(:password)

    User.authenticate(who, password) if who && password
  end

  def who
    session_params[:who].is_a?(String) && session_params.fetch(:who)
  end

  def set_login_flash
    if current_user.mfa_recommended_not_yet_enabled?
      flash[:notice] = t("multifactor_auths.setup_recommended")
    elsif current_user.mfa_recommended_weak_level_enabled?
      flash[:notice] = t("multifactor_auths.strong_mfa_level_recommended")
    elsif !current_user.webauthn_enabled?
      flash[:notice_html] = t("multifactor_auths.setup_webauthn_html")
    end
  end

  def url_after_create
    if current_user.mfa_recommended_not_yet_enabled?
      new_multifactor_auth_path
    elsif current_user.mfa_recommended_weak_level_enabled?
      edit_settings_path
    else
      dashboard_path
    end
  end

  def ensure_not_blocked
    user = User.find_by_blocked(who)
    return unless user&.blocked_email

    flash.now.alert = t(".account_blocked")
    render template: "sessions/new", status: :unauthorized
  end

  def login_conditions_met?
    @user&.mfa_enabled? && @user&.ui_mfa_verified?(params[:otp]) && session_active?
  end

  def delete_mfa_session
    delete_mfa_expiry_session
    session.delete(:webauthn_authentication)
    session.delete(:mfa_login_started_at)
    session.delete(:mfa_user)
  end

  def record_mfa_login_duration(mfa_type:)
    started_at = Time.zone.parse(session[:mfa_login_started_at]).utc
    duration = Time.now.utc - started_at

    StatsD.distribution("login.mfa.#{mfa_type}.duration", duration)
  end
end
