# Admin-portal endpoints for granting access to identities that have already
# completed the operator Google sign-in. Operator identity records live in the
# dedicated operator database, while the acting administrator is authenticated
# by AdminAuth.
class OperatorManagementAccessesController < ApplicationController
  UUID_FORMAT = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  def index
    authorize_admin!(Operator::Identity, :index?)
    render json: operator_auth.management_identities!
  end

  def update
    require_same_origin!
    authorize_admin!(Operator::Identity, :update?)
    manager_enabled = params[:managerEnabled]
    return render_error("managerEnabled must be true or false", :unprocessable_content) unless [ true, false ].include?(manager_enabled)

    identity = operator_auth.set_management_access!(id: operator_identity_id!, manager_enabled:, actor: pundit_user)
    render json: operator_auth.management_identity_json(identity)
  end

  private

  def operator_identity_id!
    id = params[:id]
    raise AdminAuthError.new("identityId must be a valid UUID", :bad_request) unless id.is_a?(String) && id.match?(UUID_FORMAT)

    id
  end
end
