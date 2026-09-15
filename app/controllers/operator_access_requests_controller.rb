# Applicant-side endpoints of the operator access-request flow. Mirrors
# AccessRequestsController#show/create, but authenticates with an operator
# applicant session instead of an admin one.
class OperatorAccessRequestsController < ApplicationController
  def show
    request = operator_auth.own_access_request!
    return head :no_content unless request

    render json: request_json(request)
  end

  def create
    require_same_origin!(config: operator_auth_config)
    request = operator_auth.create_access_request!
    render json: request_json(request), status: request.pending? ? :created : :ok
  end

  private

  def request_json(request)
    {
      id: request.id,
      email: request.email,
      status: Operator::AccessRequest.statuses.fetch(request.status),
      createdAt: request.created_at.iso8601,
      expiresAt: request.expires_at.iso8601,
      cancelledAt: request.cancelled_at&.iso8601,
      cancellationReason: request.cancellation_reason,
      decidedAt: (request.approved_at || request.rejected_at)&.iso8601
    }
  end
end
