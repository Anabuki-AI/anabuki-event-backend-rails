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

  it "validates an attached image's content type and size" do
    question = described_class.new(valid_attributes.merge(position: 99))
    question.image.attach(io: StringIO.new("not an image"), filename: "notes.txt", content_type: "text/plain")

    expect(question).not_to be_valid
    expect(question.errors).to include(:image)

    question.image.attach(io: StringIO.new("\x89PNG\r\n\x1a\n".b), filename: "question.png", content_type: "image/png")
    expect(question).to be_valid

    question.image.attach(io: StringIO.new("x" * (described_class::MAX_IMAGE_BYTE_SIZE + 1)), filename: "big.png", content_type: "image/png")
    expect(question).not_to be_valid
    expect(question.errors).to include(:image)
  end
end
