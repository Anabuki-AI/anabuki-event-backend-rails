require "uri"

class Question < ApplicationRecord
  MAX_QUESTION_TEXT_LENGTH = 200
  MAX_CHOICE_LENGTH = 100
  MAX_IMAGE_URL_LENGTH = 2048
  MAX_EXPLANATION_LENGTH = 500
  MAX_TARGET_AUDIENCE_LENGTH = 100
  ALLOWED_IMAGE_CONTENT_TYPES = %w[image/webp].freeze
  MAX_IMAGE_BYTE_SIZE = 5.megabytes
  POSITION_LOCK_KEY = 6_813_271_904
  RELAY_SELECTION_LOCK_KEY = 6_813_271_905
  MIN_POINTS = 1
  MAX_POINTS = 1000
  MAX_TIME_LIMIT_SECONDS = 2_147_483_647
  RELAY_QUESTION_DEFAULT_CORRECT_ANSWER = "A"
  LIVE_FIELDS = %w[question_text choice_a choice_b choice_c choice_d correct_answer
    points time_limit_seconds image_url position is_relay_question].freeze

  has_one_attached :image

  attr_accessor :allow_live_correct_answer_change
  # Set only by Question.bulk_destroy!, which deliberately deletes used
  # (revealed / answered / live) questions. Single delete never sets it.
  attr_accessor :skip_used_question_protection

  validates :question_text, presence: true, length: { maximum: MAX_QUESTION_TEXT_LENGTH }
  validates :choice_a, :choice_b, :choice_c, :choice_d, presence: true, length: { maximum: MAX_CHOICE_LENGTH }
  validates :correct_answer, inclusion: { in: %w[A B C D] }
  validates :position, numericality: { only_integer: true, greater_than: 0 }, uniqueness: true
  validates :points, presence: true,
    numericality: { only_integer: true, greater_than_or_equal_to: MIN_POINTS, less_than_or_equal_to: MAX_POINTS }
  validates :image_url, length: { maximum: MAX_IMAGE_URL_LENGTH }, allow_nil: true
  validates :explanation, length: { maximum: MAX_EXPLANATION_LENGTH }, allow_nil: true
  validates :target_audience, length: { maximum: MAX_TARGET_AUDIENCE_LENGTH }, allow_nil: true
  validates :time_limit_seconds,
    numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: MAX_TIME_LIMIT_SECONDS }, allow_nil: true
  validate :image_url_is_http_url
  validate :image_is_valid_upload
  # Only a relay question can be "the one selected to ask this time"; a relay
  # question that is not currently selected and has never been revealed live
  # keeps whatever correct_answer it already has (correct_answer stays NOT
  # NULL) but may not have it changed via an update. Once a question has been
  # revealed (revealed_at set by QuizSession#reveal!), its round is over, so
  # a later operator selecting a different relay question to ask next must
  # not re-lock this one. This is enforced here so the guard also applies to
  # direct API calls, not just the admin UI.
  validate :correct_answer_locked_for_unselected_relay_question, on: :update

  before_validation :normalize_text_attributes
  before_validation :reset_correct_answer_when_converted_to_relay
  around_update :protect_live_question
  around_destroy :protect_used_question, prepend: true
  before_save :normalize_relay_selection
  before_save :unselect_other_relay_questions, if: :will_save_change_to_is_selected_relay_question?
  after_update :recalculate_participant_answer_scores, if: :scoring_fields_changed?

  class BulkDestroyMissing < StandardError
    attr_reader :missing_ids

    def initialize(missing_ids)
      @missing_ids = missing_ids
      super("Questions not found: #{missing_ids.join(', ')}")
    end
  end

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

    # Deletes a question and closes the gap it leaves so positions stay 1..n.
    # A used question is still rejected by the destroy callback, which raises
    # and rolls the whole transaction back.
    def destroy_and_renumber!(question)
      transaction do
        with_position_lock do
          question.destroy!
          renumber_positions_after!(question.position)
        end
      end
    end

    # Deletes every question in +ids+ in one transaction (all-or-nothing),
    # INCLUDING revealed / answered / currently live ones (their answers and
    # confidence selections go away via ON DELETE CASCADE). If the live question
    # is among them the quiz session is put back to "waiting" first, because
    # quiz_sessions.current_question_id has a plain FK. Remaining positions are
    # renumbered to 1..n. Returns the deleted ids.
    def bulk_destroy!(ids)
      ids = ids.uniq
      transaction do
        session = QuizSession.current
        session.with_lock do
          questions = where(id: ids).order(:position).to_a
          missing = ids - questions.map(&:id)
          raise BulkDestroyMissing.new(missing) if missing.any?

          session.clear_live_question! if ids.include?(session.current_question_id)
          with_position_lock do
            questions.each do |question|
              question.skip_used_question_protection = true
              question.destroy!
            end
            renumber_all_positions!
          end
          questions.map(&:id)
        end
      end
    end

    # Reassigns positions 1..n in the current order. Parks every row above the
    # current maximum first so the unique index never sees a duplicate.
    def renumber_all_positions!
      return unless exists?

      offset = maximum(:position)
      update_all([ "position = position + ?", offset ])
      connection.execute(<<~SQL.squish)
        UPDATE questions SET position = ranked.new_position
        FROM (SELECT id, ROW_NUMBER() OVER (ORDER BY position) AS new_position FROM questions) ranked
        WHERE questions.id = ranked.id
      SQL
    end

    # Shifts every position greater than +deleted_position+ down by one.
    # positions are unique and must stay > 0, so a single decrement could
    # collide mid-statement and a negative parking value violates the CHECK.
    # Park the rows above the current maximum first, then bring them back.
    def renumber_positions_after!(deleted_position)
      scope = where("position > ?", deleted_position)
      return unless scope.exists?

      offset = maximum(:position)
      scope.update_all([ "position = position + ?", offset ])
      where("position > ?", offset).update_all([ "position = position - ? - 1", offset ])
    end
  end

  private

  # Use the session -> question lock order shared by answer recording and
  # progression. Checking before taking that lock races with start/publish and
  # confidence selection (especially the server-chosen Lv.1 elimination).
  def protect_live_question
    session = QuizSession.current
    session.with_lock do
      if session.status == "in_progress" && session.current_question_id == id
        live_fields = changes_to_save.keys & LIVE_FIELDS
        live_fields -= [ "correct_answer" ] if allow_live_correct_answer_change
        live_fields.each do |field|
          errors.add(field, "cannot be changed while this question is live")
        end
        errors.add(:image, "cannot be changed while this question is live") if attachment_changes.key?("image")
        raise ActiveRecord::RecordInvalid, self if errors.any?
      end
      yield
    end
  end

  def protect_used_question
    return yield if skip_used_question_protection

    QuizSession.current.with_lock do
      if QuizSession.where(current_question_id: id).exists? || self.class.where(id:).where.not(revealed_at: nil).exists? ||
          ParticipantAnswer.where(question_id: id).exists? ||
          ParticipantQuizConfidenceSelection.where(question_id: id).exists?
        errors.add(:base, "A current or previously used question cannot be deleted")
        raise ActiveRecord::RecordNotDestroyed.new(errors.full_messages.to_sentence, self)
      end
      yield
    end
  end

  def correct_answer_locked_for_unselected_relay_question
    return unless will_save_change_to_correct_answer?
    return if allow_live_correct_answer_change
    return if converted_to_relay_question?
    return unless is_relay_question?
    return if is_selected_relay_question?
    return if revealed_at.present?

    errors.add(:correct_answer, "cannot be changed for a relay question that is not selected")
  end

  def update_live_correct_answer!(correct_answer)
    self.allow_live_correct_answer_change = true
    update!(correct_answer:, live_correct_answer_confirmed_at: Time.current)
  ensure
    self.allow_live_correct_answer_change = false
  end

  public :update_live_correct_answer!

  # Non-relay questions never carry a selection; keep that invariant even if
  # a caller flips is_relay_question and is_selected_relay_question in the
  # same request.
  def normalize_relay_selection
    self.is_selected_relay_question = false unless is_relay_question?
  end

  # A relay question's answer is decided during the live quiz. When an
  # existing question is changed into a relay question, discard the ordinary
  # question's answer instead of carrying it into the new relay round. The
  # database keeps A as the required placeholder; the live operator still
  # confirms the actual answer before it is revealed.
  def reset_correct_answer_when_converted_to_relay
    return unless converted_to_relay_question?

    self.correct_answer = RELAY_QUESTION_DEFAULT_CORRECT_ANSWER
    self.live_correct_answer_confirmed_at = nil
  end

  def converted_to_relay_question?
    persisted? && will_save_change_to_is_relay_question? && is_relay_question? && attribute_in_database(:is_relay_question) == false
  end

  # At most one question may be selected at a time (enforced by a partial
  # unique index). Clear any previously selected relay question inside the
  # same transaction as this save, serialized by an advisory lock so two
  # concurrent selections cannot both observe "no other row selected".
  def unselect_other_relay_questions
    return unless is_selected_relay_question?

    self.class.connection.select_value("SELECT pg_advisory_xact_lock(#{RELAY_SELECTION_LOCK_KEY})")
    scope = self.class.where(is_selected_relay_question: true)
    scope = scope.where.not(id:) if persisted?
    scope.update_all(is_selected_relay_question: false)
  end

  def scoring_fields_changed?
    saved_change_to_correct_answer? || saved_change_to_points?
  end

  def recalculate_participant_answer_scores
    previous_correct_answer = correct_answer_before_last_save if saved_change_to_correct_answer?
    ParticipantAnswer.recalculate_for_question!(self, previous_correct_answer:)
  end

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
      errors.add(:image, "must be a WEBP file")
    end

    errors.add(:image, "must be smaller than 5MB") if image.byte_size > MAX_IMAGE_BYTE_SIZE
  end
end
