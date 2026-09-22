class ApplicationController < ActionController::API
  include ActionController::Cookies
  include Pundit::Authorization

  rescue_from ActiveRecord::RecordNotFound do
    render_error("Not found", :not_found)
  end
  rescue_from ActiveRecord::RecordInvalid do |error|
    error.record.record_rejected_moderation_audit if error.record.is_a?(Participant)
    render_error(error.record.errors.full_messages.to_sentence, :unprocessable_content)
  end
  rescue_from AdminAuthError do |error|
    render_error(error.message, error.status)
  end
  rescue_from OperatorAuthError do |error|
    render_error(error.message, error.status)
  end
  rescue_from ParticipantAuthError do |error|
    render_error(error.message, error.status)
  end

  # Object storage (Cloudflare R2 in production) failures surface here when
  # Active Storage uploads inside a save. The surrounding transaction has
  # already rolled back, so no partial DB state remains. Class names are given
  # as strings because aws-sdk-s3 is loaded lazily by ActiveStorage.
  STORAGE_UNAVAILABLE_ERRORS = %w[
    Aws::Errors::ServiceError
    Aws::Sigv4::Errors::MissingCredentialsError
    Seahorse::Client::NetworkingError
    ActiveStorage::IntegrityError
    ActiveStorage::FileNotFoundError
  ].freeze

  rescue_from(*STORAGE_UNAVAILABLE_ERRORS) do |error|
    Rails.logger.error("[storage] #{error.class}: #{error.message}\n#{Array(error.backtrace).first(20).join("\n")}")
    Sentry.capture_exception(error) if defined?(Sentry) && Sentry.initialized?
    render_error("画像の保存に失敗しました。時間をおいて再度お試しください。", :bad_gateway)
  end

  private

  # AdminAuth remains the single authority for validating the device-bound
  # session. Policies receive its already-validated, read-only session context.
  def pundit_user
    @pundit_user ||= admin_auth.any_session!
  end

  def authorize_admin!(record, query)
    authorize(record, query)
  rescue Pundit::NotAuthorizedError
    message = pundit_user.applicant? ? "Management page access is required" : "Required permission is missing"
    raise AdminAuthError.new(message, :forbidden)
  end

  # Event-operation APIs accept either an AdminAuth management session or an
  # OperatorAuth manager session. Admin access deliberately does not depend on
  # a second operator cookie, while operator-only users retain full access to
  # the operational screens.
  def authorize_event_operator!
    @authorized_event_operator_session = admin_auth.management_session!("MANAGEMENT_PAGE_VIEW")
  rescue AdminAuthError => admin_error
    begin
      @authorized_event_operator_session = operator_auth.manager_session!
    rescue OperatorAuthError
      raise admin_error
    end
  end

  def render_error(message, status)
    render json: { error: message }, status: status
  end

  def render_attached_question_image(question)
    return head :not_found unless question.image.attached?

    response.headers["Cache-Control"] = "private, no-store"
    send_data question.image.download, type: question.image.content_type, disposition: "inline"
  end

  # Audit attribution must use the exact session selected by
  # authorize_event_operator!. Re-resolving cookies here could incorrectly
  # prefer an admin applicant over the operator manager that authorized access.
  def audit_actor_identity
    session = @authorized_event_operator_session
    raise "event operator authorization must run before audit actor resolution" unless session

    session.identity
  end

  def require_same_origin!(config: admin_auth_config)
    origin = request.headers["Origin"]
    return if origin.blank? || config.allowed_origin?(origin)

    raise AdminAuthError.new("Origin is not allowed", :forbidden)
  end

  def admin_auth_config
    @admin_auth_config ||= AdminAuthConfig.new
  end

  def admin_auth
    @admin_auth ||= AdminAuth.new(cookies:, config: admin_auth_config)
  end

  def participant_auth_config
    @participant_auth_config ||= ParticipantAuthConfig.new
  end

  def participant_auth
    @participant_auth ||= ParticipantAuth.new(cookies:, config: participant_auth_config)
  end

  def require_participant_same_origin!
    origin = request.headers["Origin"]
    return if origin.blank? || participant_auth_config.allowed_origin?(origin)

    raise ParticipantAuthError.new("Origin is not allowed", :forbidden)
  end

  def operator_auth_config
    @operator_auth_config ||= OperatorAuthConfig.new
  end

  def operator_auth
    @operator_auth ||= OperatorAuth.new(cookies:, config: operator_auth_config)
  end
end
