class AccessRequestsController < ApplicationController
  def show
    request = admin_auth.own_access_request!
    return head :no_content unless request

    render json: request_json(request)
  end

  def create
    require_same_origin!
    request = admin_auth.create_access_request!
    render json: request_json(request), status: request.pending? ? :created : :ok
  end

  def index
    render json: admin_auth.pending_access_requests!.map { |request| request_json(request) }
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
    request = admin_auth.decide_access_request!(id: positive_id!, approved:)
    render json: request_json(request)
  end

  def positive_id!
    id = Integer(params[:id], exception: false)
    raise AdminAuthError.new("id must be positive", :bad_request) unless id&.positive?

    id
  end

  def request_json(request)
    {
      id: request.id,
      email: request.email,
      status: AdminAccessRequest.statuses.fetch(request.status),
      createdAt: request.created_at.iso8601,
      expiresAt: request.expires_at.iso8601,
      cancelledAt: request.cancelled_at&.iso8601,
      cancellationReason: request.cancellation_reason,
      decidedAt: (request.approved_at || request.rejected_at)&.iso8601
    }
  end
end
