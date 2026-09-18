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
end
