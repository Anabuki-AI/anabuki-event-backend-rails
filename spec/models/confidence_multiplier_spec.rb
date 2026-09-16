require "rails_helper"

RSpec.describe ConfidenceMultiplier do
  it "creates missing defaults without overwriting configured values" do
    defaults = described_class.all_levels
    defaults.fetch("high").update!(confidence_multiplier: 3.25)
    defaults.fetch("low").destroy!

    values = described_class.all_levels

    expect(values).to include("high", "normal", "low")
    expect(values.fetch("high").confidence_multiplier).to eq(BigDecimal("3.25"))
    expect(values.fetch("low").confidence_multiplier).to eq(BigDecimal("0.50"))
  end

  it "limits multipliers to the supported levels, range, and two decimal places" do
    multiplier = described_class.new(level: "high", confidence_multiplier: 1.234)
    invalid_level = described_class.new(level: "unexpected", confidence_multiplier: 1)
    out_of_range = described_class.new(level: "normal", confidence_multiplier: 10)

    expect(multiplier).not_to be_valid
    expect(multiplier.errors).to be_added(:confidence_multiplier, "must have at most two decimal places")
    expect(invalid_level).not_to be_valid
    expect(out_of_range).not_to be_valid
  end
end
