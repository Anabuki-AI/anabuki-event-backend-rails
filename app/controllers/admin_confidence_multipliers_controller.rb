class AdminConfidenceMultipliersController < ApplicationController
  def index
    authorize_event_operator!
    render json: multipliers_json(ConfidenceMultiplier.all_levels)
  end

  def update
    require_same_origin!
    authorize_event_operator!

    level = params[:level].to_s
    unless ConfidenceMultiplier::LEVELS.include?(level)
      return render_error("level must be high, normal, or low", :unprocessable_content)
    end

    value = params[:confidenceMultiplier]
    return render_error("confidenceMultiplier must be a number", :unprocessable_content) unless value.is_a?(Numeric)

    multiplier = ConfidenceMultiplier.all_levels.fetch(level)
    multiplier.update!(confidence_multiplier: value)
    AuditLogRecorder.record(type: "CONFIDENCE_MULTIPLIER_UPDATED", identity: audit_actor_identity, target_type: "CONFIDENCE_MULTIPLIER", target_id: multiplier.level, detail: { "level" => multiplier.level, "confidenceMultiplier" => value.to_f })
    render json: multipliers_json(ConfidenceMultiplier.all_levels)
  end

  private

  def multipliers_json(multipliers)
    ConfidenceMultiplier::LEVELS.index_with do |level|
      format("%.2f", multipliers.fetch(level).confidence_multiplier)
    end
  end
end
