class QuizEventTransitionError < StandardError
  attr_reader :status

  def initialize(message, status = :conflict)
    super(message)
    @status = status
  end
end
