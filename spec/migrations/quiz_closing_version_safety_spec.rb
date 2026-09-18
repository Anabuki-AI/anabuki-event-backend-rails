require "rails_helper"
require Rails.root.join("db/migrate/20260918070300_add_is_relay_question_to_questions")
require Rails.root.join("db/migrate/20260918070400_ensure_quiz_sessions_support_closing")

RSpec.describe "quiz closing migration version safety" do
  let(:connection) { ApplicationRecord.connection }

  it "loads unique published migration versions without renumbering history" do
    migrations = connection.pool.migration_context.migrations
    versions = migrations.map(&:version)
    expect(versions.uniq).to eq(versions)
    expect(migrations.find { |migration| migration.version == 20260918070000 }.name).to eq("AddClosingPhaseToQuizSessions")
    expect(migrations.find { |migration| migration.version == 20260918070300 }.name).to eq("AddIsRelayQuestionToQuestions")
  end

  [ :closing_applied, :relay_applied ].each do |history|
    it "preserves relay values and session data when #{history} occupied version 20260918070000" do
      question = Question.create!(position: 1, question_text: "Question", choice_a: "A", choice_b: "B", choice_c: "C", choice_d: "D", correct_answer: "A", is_relay_question: true)
      session = QuizSession.current
      session.start!
      original = session.attributes
      if history == :relay_applied
        connection.remove_check_constraint(:quiz_sessions, name: "quiz_sessions_phase")
        connection.add_check_constraint(:quiz_sessions, "phase IS NULL OR phase IN ('answering', 'closed', 'revealed')", name: "quiz_sessions_phase")
      end

      ActiveRecord::Migration.suppress_messages do
        AddIsRelayQuestionToQuestions.new.migrate(:up)
        EnsureQuizSessionsSupportClosing.new.migrate(:up)
        EnsureQuizSessionsSupportClosing.new.migrate(:up)
      end

      expect(question.reload.is_relay_question).to be(true)
      expect(session.reload.attributes).to eq(original)
      expect { session.update!(phase: "closing") }.not_to raise_error
      constraints = connection.check_constraints(:quiz_sessions).select { |check| check.name == "quiz_sessions_phase" }
      expect(constraints.size).to eq(1)
      expect(constraints.first.expression).to include("closing")
    end
  end

  it "refuses to guess the pre-reconciliation schema on rollback" do
    expect { EnsureQuizSessionsSupportClosing.new.down }.to raise_error(ActiveRecord::IrreversibleMigration)
  end
end
