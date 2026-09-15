class OperatorAuthController < ApplicationController
  def session
    operator = operator_auth.session!
    render json: {
      email: operator.identity.email,
      googleSub: operator.identity.google_sub,
      expiresAt: operator.record.expires_at.iso8601
    }
  end

  def logout
    require_same_origin!(config: operator_auth_config)
    operator_auth.logout!
    head :no_content
  end
end
