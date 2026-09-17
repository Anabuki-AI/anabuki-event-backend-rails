class Operator::Identity < Operator::ApplicationRecord
  encrypts :email, deterministic: true

  has_many :operator_device_sessions, class_name: "Operator::DeviceSession", foreign_key: :operator_identity_id, dependent: :destroy

  # Emails are normalized before validation/encryption, so exact deterministic
  # lookup and a normal unique index provide the Google identity invariant.
  validates :email, presence: true, length: { maximum: 320 }, format: { with: URI::MailTo::EMAIL_REGEXP }, uniqueness: true
  validates :google_sub, presence: true, length: { maximum: 255 }, uniqueness: true

  before_validation :normalize_email

  private

  def normalize_email
    self.email = email.to_s.strip.downcase
  end
end
