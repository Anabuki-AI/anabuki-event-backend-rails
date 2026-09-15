require "securerandom"

class ParticipantIdentity < ApplicationRecord
  GENDERS = [ "男性", "女性", "回答しない" ].freeze
  AGE_GROUPS = [ "10代", "20代", "30代", "40代", "50代", "60代以上" ].freeze
  SCHOOL_DEPARTMENTS = {
    "専門学校穴吹ITビジネスカレッジ" => [ "情報システム学科", "ITテクノロジー学科", "AIテクノロジー学科", "ネットワークセキュリティ学科", "未来創造ビジネス学科", "外語ビジネス学科", "公務員ビジネス学科", "公務員学科", "こども保育学科", "パティシエ・ベーカリー学科", "日本語学科", "国際ITエンジニア学科", "国際ビジネス学科", "国際ビジネス・ホテル学科", "国際ビジネスベーシック学科" ],
    "専門学校穴吹デザインカレッジ" => [ "グラフィックデザイン学科", "マンガ・コミックイラスト学科", "トータルインテリア学科", "ネット動画クリエイター学科", "ゲームクリエイター学科", "地域デザイン学科", "デザイン・イノベーション学科" ],
    "専門学校穴吹ビューティカレッジ" => [ "美容学科", "ビューティコーディネーター学科", "トータルエステティック学科", "ブライダル学科", "ビューティ・プロフェッショナル学科" ],
    "専門学校穴吹工科カレッジ" => [ "自動車整備学科（2年制）", "自動車整備学科（3年制）" ],
    "専門学校穴吹リハビリテーションカレッジ" => [ "理学療法学科", "作業療法学科" ],
    "専門学校穴吹動物看護カレッジ" => [ "動物看護総合学科", "動物健康管理学科（ペット美容・グルーマー専攻）", "動物健康管理学科（しつけインストラクター専攻）" ],
    "穴吹医療大学校" => [ "看護学科", "歯科衛生学科", "医療ビジネス学科", "医療事務・ドクター秘書学科", "介護福祉学科" ]
  }.freeze

  # ASCII visible punctuation is allowed, while spaces, controls, bidi marks,
  # emoji, and other invisible characters are not. Japanese letters are kept
  # intentionally separate from the punctuation allowance.
  # U+30FC is the Japanese prolonged-sound mark (e.g. "ユーザー"). Ruby
  # categorizes it as a modifier letter rather than Katakana.
  USER_NAME_FORMAT = /\A[\p{Hiragana}\p{Katakana}\p{Han}\u30FCA-Za-z0-9\uFF10-\uFF19\uFF21-\uFF3A\uFF41-\uFF5A!\"#$%&'()*+,\-.\/:;<=>?@\[\\\]^_`{|}~]+\z/

  has_many :participant_device_sessions, dependent: :restrict_with_exception

  before_validation :normalize_attributes
  before_validation :generate_uuid, on: :create

  validates :uuid, presence: true, uniqueness: true
  validates :user_name, presence: true, length: { minimum: 3, maximum: 20 }
  # PostgreSQL cannot quote a value containing a NUL byte.  Check the
  # permitted character set before attempting the uniqueness query so an
  # invalid nickname always receives the normal validation response.
  validates :user_name, uniqueness: true, unless: :user_name_uses_unsupported_characters?
  validates :gender, presence: true, inclusion: { in: GENDERS }
  validates :age_group, presence: true, inclusion: { in: AGE_GROUPS }
  validates :school, length: { maximum: 100 }, allow_nil: true
  validates :department, length: { maximum: 100 }, allow_nil: true
  validate :user_name_uses_allowed_characters
  validate :school_and_department_match
  validate :terms_were_explicitly_accepted

  attr_readonly :uuid

  private

  def normalize_attributes
    self.user_name = normalize_user_name(user_name)
    self.school = normalize_optional_text(school)
    self.department = normalize_optional_text(department)
    self.department = nil if school.blank? || !SCHOOL_DEPARTMENTS.key?(school)
  end

  def normalize_user_name(value)
    return value unless value.is_a?(String)

    value.unicode_normalize(:nfc).gsub(/\A +| +\z/, "")
  end

  def normalize_optional_text(value)
    return value unless value.is_a?(String)
    return nil if value.match?(/\A[[:space:]]*\z/)

    value.gsub(/\A +| +\z/, "")
  end

  def generate_uuid
    self.uuid ||= SecureRandom.uuid
  end

  def user_name_uses_allowed_characters
    return unless user_name_uses_unsupported_characters?

    errors.add(:user_name, "contains unsupported characters")
  end

  def user_name_uses_unsupported_characters?
    user_name.present? && !user_name.match?(USER_NAME_FORMAT)
  end

  def school_and_department_match
    departments = SCHOOL_DEPARTMENTS[school]
    return unless departments

    if department.blank?
      errors.add(:department, "is required for the selected school")
    elsif !departments.include?(department)
      errors.add(:department, "does not belong to the selected school")
    end
  end

  def terms_were_explicitly_accepted
    return if agreed_terms_before_type_cast == true

    errors.add(:agreed_terms, "must be accepted")
  end
end
