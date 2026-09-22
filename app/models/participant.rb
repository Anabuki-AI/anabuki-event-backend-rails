class Participant < ApplicationRecord
  has_many :participant_sessions, dependent: :destroy

  validates :display_name, presence: true, length: { maximum: 100 }, uniqueness: { case_sensitive: false }
  validate :display_name_must_be_appropriate, if: :display_name_moderation_required?
  validates :gender, :age_group, presence: true, length: { maximum: 50 }
  validates :student_type, length: { maximum: 50 }
  validates :school, :department, length: { maximum: 255 }
  validates :agreed_terms, inclusion: { in: [ true ] }

  # Called once a rejected save has rolled back (a validation failure never
  # opens a record-level transaction, so after_rollback never fires). The
  # pending result is consumed; writing here lands outside the failed save.
  def record_rejected_moderation_audit
    result = @pending_display_name_moderation_audit
    @pending_display_name_moderation_audit = nil
    return unless result

    record_display_name_moderation_audit(result)
  end

  private

  def display_name_moderation_required?
    display_name.present? && will_save_change_to_display_name?
  end

  def display_name_must_be_appropriate
    result = DisplayNameModeration.new.check(display_name)
    if result.evaluation_failed && !result.rejected?
      # Fail-open: the registration still succeeds, so the audit row persists
      # with it. Rejected results are deferred to
      # record_rejected_moderation_audit, because an audit row written inside
      # this save would roll back together with it.
      record_display_name_moderation_audit(result)
    elsif result.rejected?
      @pending_display_name_moderation_audit = result
    end
    return unless result.rejected?

    errors.add(:display_name, :inappropriate)
  end

  # Only rejections and provider failures leave a trail; a passing name needs
  # no audit row (the participant simply exists).
  def record_display_name_moderation_audit(result)
    if result.evaluation_failed
      AuditLogRecorder.record(
        type: "DISPLAY_NAME_MODERATION_FAILED",
        target_type: "PARTICIPANT",
        target_id: id,
        detail: { "displayName" => display_name, "failClosed" => result.rejected? }
      )
    elsif result.rejected?
      AuditLogRecorder.record(
        type: "DISPLAY_NAME_REJECTED",
        target_type: "PARTICIPANT",
        target_id: id,
        detail: {
          "displayName" => display_name,
          "probability" => result.probability,
          "threshold" => result.threshold
        }
      )
    end
  end
end
