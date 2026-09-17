class ApplicationController < ActionController::API
  include ActionController::Cookies
  include Pundit::Authorization

  rescue_from ActiveRecord::RecordNotFound do
    render_error("Not found", :not_found)
  end
  rescue_from ActiveRecord::RecordInvalid do |error|
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
    admin_auth.management_session!("MANAGEMENT_PAGE_VIEW")
  rescue AdminAuthError => admin_error
    begin
      operator_auth.manager_session!
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

  # Resolves the acting identity for audit logging: the admin session identity
  # when present, otherwise the operator manager session identity. The recorder
  # keeps an email/sub snapshot for operators (no audit-log foreign key).
  def audit_actor_identity
    begin
      return admin_auth.any_session!.identity
    rescue AdminAuthError
      nil
    end
    begin
      operator_auth.manager_session!.identity
    rescue OperatorAuthError
      nil
    end
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
