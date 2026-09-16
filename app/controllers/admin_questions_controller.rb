class AdminQuestionsController < ApplicationController
  QUESTION_ERROR_KEYS = {
    question_text: "questionText",
    choice_a: "choiceA",
    choice_b: "choiceB",
    choice_c: "choiceC",
    choice_d: "choiceD",
    correct_answer: "correctAnswer",
    image_url: "imageUrl",
    position: "position"
  }.freeze

  def index
    authorize_admin!(Question, :index?)
    render json: Question.order(:position).map { |question| question_json(question) }
  end

  def show
    authorize_admin!(Question, :show?)
    render json: question_json(Question.find(params[:id]))
  end

  def create
    require_same_origin!
    authorize_admin!(Question, :create?)
    return if render_question_parameter_type_errors

    question = Question.new(question_attributes)

    Question.transaction do
      Question.with_position_lock do
        question.position = Question.next_position
        question.save!
      end
    end

    render json: question_json(question), status: :created
  rescue ActiveRecord::RecordInvalid => error
    render_question_validation_error(error.record)
  end

  def update
    require_same_origin!
    authorize_admin!(Question, :update?)
    question = Question.find(params[:id])
    return if render_question_parameter_type_errors

    question.update!(question_attributes)
    render json: question_json(question)
  rescue ActiveRecord::RecordInvalid => error
    render_question_validation_error(error.record)
  end

  def destroy
    require_same_origin!
    authorize_admin!(Question, :destroy?)
    Question.find(params[:id]).destroy!
    head :no_content
  end

  private

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
      imageUrl: question.image_url,
      createdAt: question.created_at.iso8601,
      updatedAt: question.updated_at.iso8601
    }
  end
end
