class AdminQuestionsController < ApplicationController
  QUESTION_ERROR_KEYS = {
    question_text: "questionText",
    choice_a: "choiceA",
    choice_b: "choiceB",
    choice_c: "choiceC",
    choice_d: "choiceD",
    correct_answer: "correctAnswer",
    image_url: "imageUrl",
    image: "image",
    explanation: "explanation",
    target_audience: "targetAudience",
    position: "position"
  }.freeze

  def index
    authorize_event_operator!
    render json: Question.order(:position).map { |question| question_json(question) }
  end

  def show
    authorize_event_operator!
    render json: question_json(Question.find(params[:id]))
  end

  def image
    authorize_admin!(Question, :show?)
    question = Question.find(params[:id])
    return head :not_found unless question.image.attached?

    send_data question.image.download, type: question.image.content_type, disposition: "inline"
  end

  def create
    require_same_origin!
    authorize_event_operator!
    return if render_question_parameter_type_errors

    question = Question.new(question_attributes)
    assign_image(question)

    Question.transaction do
      Question.with_position_lock do
        question.position = Question.next_position
        question.save!
      end
    end

    AuditLogRecorder.record(type: "QUESTION_CREATED", identity: audit_actor_identity, target_type: "QUESTION", target_id: question.id, detail: { "position" => question.position })

    render json: question_json(question), status: :created
  rescue ActiveRecord::RecordInvalid => error
    render_question_validation_error(error.record)
  end

  def update
    require_same_origin!
    authorize_event_operator!
    question = Question.find(params[:id])
    return if render_question_parameter_type_errors

    question.assign_attributes(question_attributes)
    assign_image(question)
    question.save!
    AuditLogRecorder.record(type: "QUESTION_UPDATED", identity: audit_actor_identity, target_type: "QUESTION", target_id: question.id)
    render json: question_json(question)
  rescue ActiveRecord::RecordInvalid => error
    render_question_validation_error(error.record)
  end

  def destroy
    require_same_origin!
    authorize_event_operator!
    question = Question.find(params[:id])
    question.destroy!
    AuditLogRecorder.record(type: "QUESTION_DELETED", identity: audit_actor_identity, target_type: "QUESTION", target_id: question.id)
    head :no_content
  end

  private

  def assign_image(question)
    if params[:image].present?
      question.image.attach(params[:image])
    elsif params[:removeImage].to_s == "true" && question.persisted? && question.image.attached?
      question.image.purge
    end
  end

  def question_attributes
    attributes = {
      question_text: parameter_value(:questionText, :question_text),
      choice_a: choice_value("A", :choiceA, :choice_a),
      choice_b: choice_value("B", :choiceB, :choice_b),
      choice_c: choice_value("C", :choiceC, :choice_c),
      choice_d: choice_value("D", :choiceD, :choice_d),
      correct_answer: parameter_value(:correctAnswer, :correct_answer, :correctChoice, :correct_choice)
    }
    attributes[:image_url] = parameter_value(:imageUrl, :image_url) if image_url_provided?
    attributes[:explanation] = parameter_value(:explanation) if parameter_provided?(:explanation)
    attributes[:target_audience] = parameter_value(:targetAudience, :target_audience) if parameter_provided?(:targetAudience, :target_audience)
    attributes
  end

  # PR #16's early form sent choices as an A-D object and used correctChoice.
  # Keep those input aliases while returning the current flat API contract.
  def choice_value(key, *flat_names)
    return parameter_value(*flat_names) if parameter_provided?(*flat_names)

    choices = params[:choices]
    choices[key] if choices.respond_to?(:key?) && choices.key?(key)
  end

  def parameter_value(*names)
    names.each { |name| return params[name] if params.key?(name) }
    nil
  end

  def parameter_provided?(*names)
    names.any? { |name| params.key?(name) }
  end

  def image_url_provided?
    params.key?(:imageUrl) || params.key?(:image_url)
  end

  def render_question_parameter_type_errors
    field_errors = question_parameter_type_errors
    return false if field_errors.empty?

    render json: { error: "Invalid question parameters", fieldErrors: field_errors }, status: :unprocessable_content
    true
  end

  def question_parameter_type_errors
    values = {
      "questionText" => parameter_value(:questionText, :question_text),
      "choiceA" => choice_value("A", :choiceA, :choice_a),
      "choiceB" => choice_value("B", :choiceB, :choice_b),
      "choiceC" => choice_value("C", :choiceC, :choice_c),
      "choiceD" => choice_value("D", :choiceD, :choice_d),
      "correctAnswer" => parameter_value(:correctAnswer, :correct_answer, :correctChoice, :correct_choice)
    }
    values["imageUrl"] = parameter_value(:imageUrl, :image_url) if image_url_provided?
    values["explanation"] = parameter_value(:explanation) if parameter_provided?(:explanation)
    values["targetAudience"] = parameter_value(:targetAudience, :target_audience) if parameter_provided?(:targetAudience, :target_audience)

    values.each_with_object({}) do |(field, value), errors|
      errors[field] = "must be a string" unless value.nil? || value.is_a?(String)
    end
  end

  def render_question_validation_error(question)
    field_errors = question.errors.each_with_object({}) do |error, result|
      key = QUESTION_ERROR_KEYS.fetch(error.attribute, error.attribute.to_s.camelize(:lower))
      result[key] ||= error.message
    end
    render json: { error: question.errors.full_messages.to_sentence, fieldErrors: field_errors }, status: :unprocessable_content
  end

  def question_json(question)
    {
      id: question.id,
      position: question.position,
      questionText: question.question_text,
      choiceA: question.choice_a,
      choiceB: question.choice_b,
      choiceC: question.choice_c,
      choiceD: question.choice_d,
      correctAnswer: question.correct_answer,
      imageUrl: question_image_url(question),
      explanation: question.explanation,
      targetAudience: question.target_audience,
      createdAt: question.created_at.iso8601,
      updatedAt: question.updated_at.iso8601
    }
  end

  # Returns a path relative to the API base: an uploaded image is served from our
  # own controller action (avoids relying on Active Storage's redirect routes,
  # which the frontend's same-origin /api proxy does not forward). Falls back to
  # the legacy pasted image_url string when no file has been uploaded.
  def question_image_url(question)
    return "/admin/questions/#{question.id}/image" if question.image.attached?

    question.image_url
  end
end
