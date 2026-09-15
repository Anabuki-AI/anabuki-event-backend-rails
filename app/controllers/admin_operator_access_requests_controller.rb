# Admin-portal endpoints for approving or rejecting operator access requests.
# The admin management session is the authority; requests and sessions live in
# the operator database. Mirrors AccessRequestsController#index/approve/reject.
class AdminOperatorAccessRequestsController < ApplicationController
  UUID_FORMAT = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  def index
    authorize_admin!(Operator::AccessRequest, :index?)
    render json: operator_auth.pending_access_requests!.map { |request| request_json(request) }
  end

  def approve
    decide(true)
  end

  def reject
    decide(false)
  end

  private

  def decide(approved)
    require_same_origin!
    authorize_admin!(Operator::AccessRequest, approved ? :approve? : :reject?)
    request = operator_auth.decide_access_request!(id: request_id!, approved:, actor: pundit_user)
    render json: request_json(request)
  end

  # Operator access requests are UUID-keyed (operator schema convention),
  # so the admin controller's positive_id! check becomes a UUID format check.
  def request_id!
    id = params[:id]
    raise AdminAuthError.new("id must be a valid uuid", :bad_request) unless id.is_a?(String) && id.match?(UUID_FORMAT)

    id
  end

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
