class AdminAuthError < StandardError
  attr_reader :status

  def initialize(message, status)
    super(message)
    @status = status
  end
end
