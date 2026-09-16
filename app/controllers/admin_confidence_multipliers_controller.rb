class AdminConfidenceMultipliersController < ApplicationController
  def index
    authorize_admin!(ConfidenceMultiplier, :index?)
    render json: multipliers_json(ConfidenceMultiplier.all_levels)
  end

  def update
    require_same_origin!
    authorize_admin!(ConfidenceMultiplier, :update?)

    level = params[:level].to_s
    unless ConfidenceMultiplier::LEVELS.include?(level)
      return render_error("level must be high, normal, or low", :unprocessable_content)
    end

    value = params[:confidenceMultiplier]
    return render_error("confidenceMultiplier must be a number", :unprocessable_content) unless value.is_a?(Numeric)

    multiplier = ConfidenceMultiplier.all_levels.fetch(level)
    multiplier.update!(confidence_multiplier: value)
    render json: multipliers_json(ConfidenceMultiplier.all_levels)
  end

  private

  def multipliers_json(multipliers)
    ConfidenceMultiplier::LEVELS.index_with do |level|
      format("%.2f", multipliers.fetch(level).confidence_multiplier)
    end
  end
end
