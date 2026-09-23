class OperatorAuthController < ApplicationController
  def session
    operator = operator_auth.any_session!
    render json: session_json(operator)
  end

  def logout
    require_same_origin!(config: operator_auth_config)
    operator_auth.logout!
    head :no_content
  end


  private

  def session_json(session)
    {
      email: session.identity.email,
      googleSub: session.identity.google_sub,
      accessSource: session.source,
      expiresAt: session.record.expires_at.iso8601
    }
  end
end
