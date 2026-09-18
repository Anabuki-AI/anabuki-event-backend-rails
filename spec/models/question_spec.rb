require "rails_helper"

RSpec.describe Question do
  def valid_attributes
    {
      position: 1,
      question_text: " 問題文 ",
      choice_a: " A ",
      choice_b: " B ",
      choice_c: " C ",
      choice_d: " D ",
      correct_answer: " A ",
      image_url: " https://example.com/question.png "
    }
  end

  it "trims persisted text and accepts a nullable HTTP(S) image URL" do
    question = described_class.create!(valid_attributes)

    expect(question).to have_attributes(
      question_text: "問題文", choice_a: "A", choice_b: "B", choice_c: "C", choice_d: "D",
      correct_answer: "A", image_url: "https://example.com/question.png"
    )

    question.update!(image_url: "  ")
    expect(question.image_url).to be_nil
  end

  it "validates required text, limits, answer, position, and image URL" do
    question = described_class.new(valid_attributes.merge(
      position: 0,
      question_text: "x" * 201,
      choice_a: "x" * 101,
      correct_answer: "E",
      image_url: "ftp://example.com/image.png"
    ))

    expect(question).not_to be_valid
    expect(question.errors).to include(:position, :question_text, :choice_a, :correct_answer, :image_url)
  end

  it "defaults points to 100 and validates it is within range" do
    question = described_class.create!(valid_attributes)
    expect(question.points).to eq(100)

    question.points = 0
    expect(question).not_to be_valid
    expect(question.errors).to include(:points)

    question.points = described_class::MAX_POINTS + 1
    expect(question).not_to be_valid
    expect(question.errors).to include(:points)

    question.points = nil
    expect(question).not_to be_valid
    expect(question.errors).to include(:points)

    question.points = described_class::MIN_POINTS
    expect(question).to be_valid
  end

  it "requires a unique positive integer position" do
    described_class.create!(valid_attributes)
    duplicate = described_class.new(valid_attributes.merge(question_text: "別の問題"))

    expect(duplicate).not_to be_valid
    expect(duplicate.errors.where(:position, :taken)).to be_present
  end

  it "trims persisted explanation and target audience text" do
    question = described_class.create!(valid_attributes.merge(explanation: " 解説です ", target_audience: " 初級者向け "))
    expect(question).to have_attributes(explanation: "解説です", target_audience: "初級者向け")

    question.update!(explanation: "  ", target_audience: "  ")
    expect(question.explanation).to be_nil
    expect(question.target_audience).to be_nil
  end

  it "limits explanation and target audience length" do
    question = described_class.new(valid_attributes.merge(explanation: "x" * 501, target_audience: "x" * 101))

    expect(question).not_to be_valid
    expect(question.errors).to include(:explanation, :target_audience)
  end

  it "allows a nil time_limit_seconds (no timer) and rejects non-positive values" do
    untimed = described_class.new(valid_attributes.merge(time_limit_seconds: nil))
    expect(untimed).to be_valid

    timed = described_class.new(valid_attributes.merge(position: 2, time_limit_seconds: 30))
    expect(timed).to be_valid

    zero = described_class.new(valid_attributes.merge(position: 3, time_limit_seconds: 0))
    expect(zero).not_to be_valid
    expect(zero.errors).to include(:time_limit_seconds)

    fractional = described_class.new(valid_attributes.merge(position: 4, time_limit_seconds: 1.5))
    expect(fractional).not_to be_valid
    expect(fractional.errors).to include(:time_limit_seconds)
  end

  %w[answering closing closed revealed].each do |phase|
    it "protects current question gameplay fields during #{phase}, even with no answers" do
      question = described_class.create!(valid_attributes)
      QuizSession.current.update!(status: "in_progress", current_question: question, phase:)

      expect { question.update!(correct_answer: "B", choice_a: "Changed", points: 200, time_limit_seconds: 5) }
        .to raise_error(ActiveRecord::RecordInvalid)
      expect(question.errors.attribute_names).to include(:correct_answer, :choice_a, :points, :time_limit_seconds)
      expect(question.reload).to have_attributes(correct_answer: "A", choice_a: "A", points: 100, time_limit_seconds: nil)
      expect { question.destroy! }.to raise_error(ActiveRecord::RecordNotDestroyed)
    end
  end

  it "allows future question edits while another question is live" do
    described_class.create!(valid_attributes)
    future = described_class.create!(valid_attributes.merge(position: 2))
    QuizSession.current.start!

    expect { future.update!(correct_answer: "B", choice_a: "Changed") }.not_to raise_error
  end

  it "protects revealed history even when no participant answered and the object is stale" do
    question = described_class.create!(valid_attributes)
    stale = described_class.find(question.id)
    QuizSession.current.start!
    QuizSession.current.reveal!
    QuizSession.current.finish!

    expect { stale.destroy! }.to raise_error(ActiveRecord::RecordNotDestroyed)
    expect(described_class.exists?(question.id)).to be(true)
  end

  it "permits deleting a question again after an explicit debug reset clears its history" do
    question = described_class.create!(valid_attributes)
    QuizSession.current.start!
    QuizSession.current.reveal!
    QuizSession.current.reset!

    expect { question.destroy! }.to change(described_class, :count).by(-1)
  end

  it "validates an attached image's content type and size" do
    question = described_class.new(valid_attributes.merge(position: 99))
    question.image.attach(io: StringIO.new("not an image"), filename: "notes.txt", content_type: "text/plain")

    expect(question).not_to be_valid
    expect(question.errors).to include(:image)

    question.image.attach(io: StringIO.new("RIFFWEBP".b), filename: "question.webp", content_type: "image/webp")
    expect(question).to be_valid

    question.image.attach(io: StringIO.new("x" * (described_class::MAX_IMAGE_BYTE_SIZE + 1)), filename: "big.webp", content_type: "image/webp")
    expect(question).not_to be_valid
    expect(question.errors).to include(:image)
  end

  describe "relay question selection" do
    it "allows setting correct_answer on create even for a relay question (never selected yet)" do
      question = described_class.create!(valid_attributes.merge(is_relay_question: true))

      expect(question).to have_attributes(is_relay_question: true, is_selected_relay_question: false, correct_answer: "A")
    end

    it "rejects changing correct_answer on update for a relay question that is not selected" do
      question = described_class.create!(valid_attributes.merge(is_relay_question: true))

      question.correct_answer = "B"
      expect(question).not_to be_valid
      expect(question.errors.where(:correct_answer)).to be_present
      expect { question.save! }.to raise_error(ActiveRecord::RecordInvalid)
    end

    it "allows changing correct_answer on update once the relay question is selected" do
      question = described_class.create!(valid_attributes.merge(is_relay_question: true))
      question.update!(is_selected_relay_question: true)

      question.update!(correct_answer: "B")
      expect(question.reload.correct_answer).to eq("B")
    end

    it "allows the live quiz session to set the correct answer for a selected relay question" do
      question = described_class.create!(valid_attributes.merge(is_relay_question: true, is_selected_relay_question: true))
      session = QuizSession.current
      session.start!

      expect { session.update_live_correct_answer!("C") }.not_to raise_error
      question.reload
      expect(question.correct_answer).to eq("C")
      expect(question.live_correct_answer_confirmed_at).to be_present
    end

    it "rejects a live correct_answer change for a relay question that is not selected" do
      described_class.create!(valid_attributes.merge(is_relay_question: true))
      session = QuizSession.current
      session.start!

      expect { session.update_live_correct_answer!("C") }.to raise_error(QuizSession::InvalidTransition)
    end

    it "rejects a live correct_answer change once the question has been revealed" do
      question = described_class.create!(valid_attributes.merge(is_relay_question: true, is_selected_relay_question: true))
      session = QuizSession.current
      session.start!
      session.reveal!

      expect { session.update_live_correct_answer!("C") }.to raise_error(QuizSession::InvalidTransition)
      expect(question.reload.correct_answer).to eq("A")
    end

    it "still enforces the live-question lock for fields other than correct_answer during a live correct_answer update" do
      question = described_class.create!(valid_attributes.merge(is_relay_question: true, is_selected_relay_question: true))
      session = QuizSession.current
      session.start!

      question.allow_live_correct_answer_change = true
      question.correct_answer = "C"
      question.question_text = "書き換え禁止"
      expect { question.save! }.to raise_error(ActiveRecord::RecordInvalid)
      expect(question.errors[:question_text]).to be_present
      expect(question.errors[:correct_answer]).to be_empty
    end

    it "allows changing correct_answer on update for a non-relay question regardless of selection" do
      question = described_class.create!(valid_attributes)

      question.update!(correct_answer: "C")
      expect(question.reload.correct_answer).to eq("C")
    end

    it "allows selecting and changing correct_answer in the same update" do
      question = described_class.create!(valid_attributes.merge(is_relay_question: true))

      question.update!(is_selected_relay_question: true, correct_answer: "D")
      expect(question.reload).to have_attributes(is_selected_relay_question: true, correct_answer: "D")
    end

    it "selects only one relay question at a time, deselecting the previous selection" do
      first = described_class.create!(valid_attributes.merge(is_relay_question: true))
      second = described_class.create!(valid_attributes.merge(position: 2, question_text: "2問目", is_relay_question: true))

      first.update!(is_selected_relay_question: true)
      expect(first.reload.is_selected_relay_question).to be(true)

      second.update!(is_selected_relay_question: true)
      expect(second.reload.is_selected_relay_question).to be(true)
      expect(first.reload.is_selected_relay_question).to be(false)
    end

    it "allows deselecting a relay question, leaving none selected" do
      question = described_class.create!(valid_attributes.merge(is_relay_question: true))
      question.update!(is_selected_relay_question: true)

      question.update!(is_selected_relay_question: false)
      expect(question.reload.is_selected_relay_question).to be(false)
    end

    it "forces is_selected_relay_question to false when a question is not (or is no longer) a relay question" do
      non_relay = described_class.create!(valid_attributes.merge(is_selected_relay_question: true))
      expect(non_relay.reload.is_selected_relay_question).to be(false)

      relay = described_class.create!(valid_attributes.merge(position: 2, question_text: "2問目", is_relay_question: true))
      relay.update!(is_selected_relay_question: true)

      relay.update!(is_relay_question: false)
      expect(relay.reload).to have_attributes(is_relay_question: false, is_selected_relay_question: false)
    end

    it "allows changing correct_answer on update for a relay question that has already been revealed, even once unselected" do
      question = described_class.create!(valid_attributes.merge(is_relay_question: true))
      question.update!(is_selected_relay_question: true, revealed_at: Time.current)

      # Selecting a different relay question deselects this one (see
      # "selects only one relay question at a time" above), which would
      # re-lock a never-asked question but must not re-lock one whose round
      # is already over.
      other = described_class.create!(valid_attributes.merge(position: 2, question_text: "2問目", is_relay_question: true))
      other.update!(is_selected_relay_question: true)
      expect(question.reload.is_selected_relay_question).to be(false)

      question.update!(correct_answer: "B")
      expect(question.reload.correct_answer).to eq("B")
    end

    it "still rejects changing correct_answer for a relay question that is unselected and has never been revealed" do
      question = described_class.create!(valid_attributes.merge(is_relay_question: true))
      question.update!(is_selected_relay_question: true)
      question.update!(is_selected_relay_question: false)

      question.correct_answer = "B"
      expect(question).not_to be_valid
      expect(question.errors.where(:correct_answer)).to be_present
    end
  end
end
