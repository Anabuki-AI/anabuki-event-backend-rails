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

  def render_error(message, status)
    render json: { error: message }, status: status
  end

  def require_same_origin!
    origin = request.headers["Origin"]
    return if origin.blank? || admin_auth_config.allowed_origin?(origin)

    raise AdminAuthError.new("Origin is not allowed", :forbidden)
  end

  def admin_auth_config
    @admin_auth_config ||= AdminAuthConfig.new
  end

  def admin_auth
    @admin_auth ||= AdminAuth.new(cookies:, config: admin_auth_config)
  end
end
