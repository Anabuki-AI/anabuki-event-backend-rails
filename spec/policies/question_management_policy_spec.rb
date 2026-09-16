require "rails_helper"

RSpec.describe "Question management policies" do
  it "allows only sessions with the existing management page permission" do
    applicant = AdminAuth::Session.new(nil, nil, "APPLICANT", [])
    manager = AdminAuth::Session.new(nil, nil, "MANAGEMENT_ACCESS", [ "MANAGEMENT_PAGE_VIEW" ])

    expect(QuestionPolicy.new(applicant, Question)).not_to be_index
    expect(ConfidenceMultiplierPolicy.new(applicant, ConfidenceMultiplier)).not_to be_index
    expect(QuestionPolicy.new(manager, Question)).to be_index
    expect(ConfidenceMultiplierPolicy.new(manager, ConfidenceMultiplier)).to be_index

    question_policy = QuestionPolicy.new(manager, Question)
    expect(question_policy).to be_create
    expect(question_policy).to be_update
    expect(question_policy).to be_destroy
    expect(ConfidenceMultiplierPolicy.new(manager, ConfidenceMultiplier)).to be_update
  end
end
