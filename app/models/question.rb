require "uri"

class Question < ApplicationRecord
  MAX_QUESTION_TEXT_LENGTH = 200
  MAX_CHOICE_LENGTH = 100
  MAX_IMAGE_URL_LENGTH = 2048
  MAX_EXPLANATION_LENGTH = 500
  MAX_TARGET_AUDIENCE_LENGTH = 100
  ALLOWED_IMAGE_CONTENT_TYPES = %w[image/png image/jpeg image/webp image/gif].freeze
  MAX_IMAGE_BYTE_SIZE = 5.megabytes
  POSITION_LOCK_KEY = 6_813_271_904

  has_one_attached :image

  validates :question_text, presence: true, length: { maximum: MAX_QUESTION_TEXT_LENGTH }
  validates :choice_a, :choice_b, :choice_c, :choice_d, presence: true, length: { maximum: MAX_CHOICE_LENGTH }
  validates :correct_answer, inclusion: { in: %w[A B C D] }
  validates :position, numericality: { only_integer: true, greater_than: 0 }, uniqueness: true
  validates :image_url, length: { maximum: MAX_IMAGE_URL_LENGTH }, allow_nil: true
  validates :explanation, length: { maximum: MAX_EXPLANATION_LENGTH }, allow_nil: true
  validates :target_audience, length: { maximum: MAX_TARGET_AUDIENCE_LENGTH }, allow_nil: true
  validate :image_url_is_http_url
  validate :image_is_valid_upload

  before_validation :normalize_text_attributes

  class << self
    # PostgreSQL advisory locks serialize position allocation even before a
    # first row exists, avoiding duplicate positions from concurrent creates.
    def with_position_lock
      connection.select_value("SELECT pg_advisory_xact_lock(#{POSITION_LOCK_KEY})")
      yield
    end

    def next_position
      maximum(:position).to_i + 1
    end
  end

  private

  def normalize_text_attributes
    self.question_text = question_text.to_s.strip
    self.choice_a = choice_a.to_s.strip
    self.choice_b = choice_b.to_s.strip
    self.choice_c = choice_c.to_s.strip
    self.choice_d = choice_d.to_s.strip
    self.correct_answer = correct_answer.to_s.strip
    self.image_url = image_url.nil? ? nil : image_url.to_s.strip.presence
    self.explanation = explanation.nil? ? nil : explanation.to_s.strip.presence
    self.target_audience = target_audience.nil? ? nil : target_audience.to_s.strip.presence
  end

  def image_url_is_http_url
    return if image_url.nil?

    uri = URI.parse(image_url)
    return if uri.is_a?(URI::HTTP) && uri.host.present?

    errors.add(:image_url, "must be a valid HTTP or HTTPS URL")
  rescue URI::InvalidURIError
    errors.add(:image_url, "must be a valid HTTP or HTTPS URL")
  end

  def image_is_valid_upload
    return unless image.attached?

    unless image.content_type.in?(ALLOWED_IMAGE_CONTENT_TYPES)
      errors.add(:image, "must be a PNG, JPEG, WEBP, or GIF file")
    end

    errors.add(:image, "must be smaller than 5MB") if image.byte_size > MAX_IMAGE_BYTE_SIZE
  end
end
