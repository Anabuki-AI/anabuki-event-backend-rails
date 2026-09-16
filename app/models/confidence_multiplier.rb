class ConfidenceMultiplier < ApplicationRecord
  LEVELS = %w[high normal low].freeze
  DEFAULTS = {
    "high" => BigDecimal("2.00"),
    "normal" => BigDecimal("1.00"),
    "low" => BigDecimal("0.50")
  }.freeze

  validates :level, inclusion: { in: LEVELS }, uniqueness: true
  validates :confidence_multiplier,
    numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: BigDecimal("9.99") }
  validate :confidence_multiplier_has_at_most_two_decimal_places

  def self.all_levels
    now = Time.current
    insert_all(
      DEFAULTS.map do |level, confidence_multiplier|
        { level:, confidence_multiplier:, created_at: now, updated_at: now }
      end,
      unique_by: :index_confidence_multipliers_on_level
    )
    where(level: LEVELS).index_by(&:level)
  end

  private

  def confidence_multiplier_has_at_most_two_decimal_places
    raw_value = confidence_multiplier_before_type_cast
    return if raw_value.nil?

    value = BigDecimal(raw_value.to_s)
    return if value == value.round(2)

    errors.add(:confidence_multiplier, "must have at most two decimal places")
  rescue ArgumentError
    # The numericality validator reports non-numeric values.
  end
end
