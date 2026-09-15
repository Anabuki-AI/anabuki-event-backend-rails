class ParticipantUsersController < ApplicationController
  def create
    require_same_origin!

    if (identity = participant_auth.current_identity)
      return render json: participant_json(identity)
    end

    return render_error("Invalid request", :unprocessable_content) unless valid_parameter_types?

    identity = ParticipantIdentity.new(participant_params)
    ParticipantIdentity.transaction(requires_new: true) do
      identity.save!
      participant_auth.establish_session!(identity)
    end
    render json: participant_json(identity), status: :created
  rescue ActiveRecord::RecordInvalid
    if identity.errors[:user_name].any?
      render_error("このユーザー名は使用できません", identity.errors.of_kind?(:user_name, :taken) ? :conflict : :unprocessable_content)
    elsif identity.errors[:agreed_terms].any?
      render_error("利用規約への同意が必要です", :unprocessable_content)
    else
      render_error(identity.errors.full_messages.to_sentence, :unprocessable_content)
    end
  rescue ParticipantAuth::SessionCreationError
    render_error("Participant session could not be created", :internal_server_error)
  rescue ActiveRecord::RecordNotUnique
    render_error("このユーザー名は使用できません", :conflict)
  end

  private

  def participant_auth
    @participant_auth ||= ParticipantAuth.new(cookies:)
  end

  def participant_params
    {
      user_name: params[:userName],
      gender: params[:gender],
      age_group: params[:ageGroup],
      school: params[:school],
      department: params[:department],
      agreed_terms: params[:agreedTerms]
    }
  end

  def valid_parameter_types?
    %i[userName gender ageGroup school department].all? do |name|
      value = params[name]
      value.nil? || value.is_a?(String)
    end
  end

  def participant_json(identity)
    {
      uuid: identity.uuid,
      userName: identity.user_name,
      message: "ユーザー登録が完了しました"
    }
  end
end
