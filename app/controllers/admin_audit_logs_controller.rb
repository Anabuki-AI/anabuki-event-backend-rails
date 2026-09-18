# Serves the admin console audit trail (docs/audit-log-contract.md):
# GET /api/admin/audit-logs with page/perPage/type/from/to filters, fixed
# occurredAt-descending order and offset paging.
class AdminAuditLogsController < ApplicationController
  DEFAULT_PAGE = 1
  DEFAULT_PER_PAGE = 50
  MAX_PER_PAGE = 100

  def index
    authorize_admin!(AuditLog, :index?)
    page = positive_integer!("page", params[:page], DEFAULT_PAGE, 1..)
    per_page = positive_integer!("perPage", params[:perPage] || params[:per_page], DEFAULT_PER_PAGE, 1..MAX_PER_PAGE)
    types = event_types!
    from = timestamp!("from", params[:from])
    to = timestamp!("to", params[:to])
    raise AdminAuthError.new("from must not be later than to", :bad_request) if from && to && from > to

    scope = AuditLog.order(occurred_at: :desc, id: :desc)
    scope = scope.where(event_type: types) if types
    scope = scope.where(occurred_at: from..) if from
    scope = scope.where(occurred_at: ..to) if to

    total_entries = scope.count
    entries = scope.offset((page - 1) * per_page).limit(per_page)

    response.headers["Cache-Control"] = "no-store"
    render json: {
      entries: entries.map { |entry| entry_json(entry) },
      page:,
      perPage: per_page,
      totalEntries: total_entries
    }
  end

  private

  def positive_integer!(name, raw, default, range)
    return default if raw.nil?

    value = Integer(raw.to_s, exception: false)
    valid = value.is_a?(Integer) && range.cover?(value)
    raise AdminAuthError.new("#{name} must be an integer in #{range}", :bad_request) unless valid

    value
  end

  def event_types!
    raw = params[:type]
    return nil if raw.blank?

    values = raw.to_s.split(",").map(&:strip).reject(&:blank?)
    invalid = values - AuditLog::EVENT_TYPES
    unless invalid.empty?
      raise AdminAuthError.new("type contains unknown audit log types: #{invalid.uniq.join(", ")}", :bad_request)
    end

    values.uniq
  end

  def timestamp!(name, raw)
    return nil if raw.blank?

    Time.iso8601(raw.to_s)
  rescue ArgumentError
    raise AdminAuthError.new("#{name} must be an RFC3339 timestamp", :bad_request)
  end

  def entry_json(entry)
    {
      id: entry.id.to_s,
      type: entry.event_type,
      actorEmail: entry.actor_email,
      actorGoogleSub: entry.actor_google_sub,
      targetType: entry.target_type,
      targetId: entry.target_id,
      operationId: entry.operation_id,
      operationStartedAt: entry.operation_started_at&.iso8601(6),
      operationCompletedAt: entry.operation_completed_at&.iso8601(6),
      detail: entry.detail,
      occurredAt: entry.occurred_at.iso8601
    }
  end
end
