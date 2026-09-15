class Operator::Identity < Operator::ApplicationRecord
  has_many :operator_device_sessions, class_name: "Operator::DeviceSession", dependent: :destroy

  validates :email, presence: true, length: { maximum: 320 }, format: { with: URI::MailTo::EMAIL_REGEXP }, uniqueness: { case_sensitive: false }
  validates :google_sub, presence: true, length: { maximum: 255 }, uniqueness: true

  before_validation :normalize_email

  private

  def normalize_email
    self.email = email.to_s.strip.downcase
  end
end
