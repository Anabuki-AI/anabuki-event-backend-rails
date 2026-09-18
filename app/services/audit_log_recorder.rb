# Writes admin audit-log entries after a succeeded action. Recording failures
# are logged and swallowed so an audit problem never turns an already-succeeded
# action into a client-visible error (docs/audit-log-contract.md: "an accepted
# write corresponds to a succeeded action").
class AuditLogRecorder
  SCALAR_TYPES = [ String, Numeric, TrueClass, FalseClass, NilClass ].freeze

  class << self
    def record(type:, identity: nil, target_type: nil, target_id: nil, detail: {}, operation_id: nil,
      operation_started_at: nil, operation_completed_at: nil, occurred_at: Time.current)
      record!(
        type:, identity:, target_type:, target_id:, detail:, operation_id:,
        operation_started_at:, operation_completed_at:, occurred_at:
      )
    rescue StandardError => error
      Rails.logger.warn("[audit_log] failed to record #{type}: #{error.class}: #{error.message}")
      nil
    end

    def record!(type:, identity: nil, target_type: nil, target_id: nil, detail: {}, operation_id: nil,
      operation_started_at: nil, operation_completed_at: nil, occurred_at: Time.current)
      raise ArgumentError, "unknown audit log type: #{type.inspect}" unless AuditLog::EVENT_TYPES.include?(type)

      AuditLog.create!(
        event_type: type,
        # Keep the audit log decoupled from operator identity lifecycle; both
        # identity types are stored in the primary database.
        admin_identity_id: identity.is_a?(AdminIdentity) ? identity.id : nil,
        actor_email: identity&.email,
        actor_google_sub: identity&.google_sub,
        target_type:,
        target_id: target_id.nil? ? nil : target_id.to_s,
        detail: sanitize_detail(detail),
        operation_id:,
        operation_started_at:,
        operation_completed_at:,
        occurred_at:
      )
    end

    private

    def sanitize_detail(detail)
      raise ArgumentError, "detail must be a Hash" unless detail.is_a?(Hash)

      detail.to_h { |key, value| [ key.to_s, sanitize_value(value) ] }
    end

    def sanitize_value(value)
      return value if SCALAR_TYPES.any? { |type| value.is_a?(type) }

      raise ArgumentError, "detail values must be scalars, got #{value.class}"
    end
  end
end
