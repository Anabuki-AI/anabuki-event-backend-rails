require "rails_helper"

RSpec.describe AuditLogRecorder do
  describe ".record!" do
    it "writes an entry with scalar-only detail and string target ids" do
      identity = AdminIdentity.create!(email: "actor@example.com", google_sub: "actor-sub")
      entry = described_class.record!(
        type: "QUESTION_CREATED",
        identity:,
        target_type: "QUESTION",
        target_id: 7,
        detail: { questionId: 7, position: 1 }
      )

      expect(entry).to have_attributes(
        event_type: "QUESTION_CREATED",
        admin_identity_id: identity.id,
        actor_email: "actor@example.com",
        actor_google_sub: "actor-sub",
        target_type: "QUESTION",
        target_id: "7"
      )
      expect(entry.detail).to eq("questionId" => 7, "position" => 1)
    end

    it "rejects unknown types, non-hash detail, and non-scalar values" do
      expect { described_class.record!(type: "MYSTERY") }.to raise_error(ArgumentError)
      expect { described_class.record!(type: "ADMIN_LOGGED_OUT", detail: "nope") }.to raise_error(ArgumentError)
      expect { described_class.record!(type: "ADMIN_LOGGED_OUT", detail: { "nested" => {} }) }.to raise_error(ArgumentError)
    end

    it "keeps only an email/sub snapshot for non-admin identities (operator database)" do
      actor = Data.define(:id, :email, :google_sub).new(SecureRandom.uuid, "operator@example.com", "operator-sub")
      entry = described_class.record!(type: "QUESTION_CREATED", identity: actor, target_type: "QUESTION", target_id: 1)
      expect(entry.admin_identity_id).to be_nil
      expect(entry.actor_email).to eq("operator@example.com")
    end
  end

  describe ".record" do
    it "swallows recording failures so succeeded actions keep their response" do
      allow(AuditLog).to receive(:create!).and_raise(ActiveRecord::RecordInvalid.new(AuditLog.new))
      allow(Rails.logger).to receive(:warn)

      expect(described_class.record(type: "ADMIN_LOGGED_OUT")).to be_nil
      expect(Rails.logger).to have_received(:warn).with(/\[audit_log\] failed to record ADMIN_LOGGED_OUT/)
    end
  end
end
