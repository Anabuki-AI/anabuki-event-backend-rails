class AdminAccessRequestPolicy < ApplicationPolicy
  def index?
    allowed?("ACCESS_REQUEST_APPROVE")
  end

  def approve?
    allowed?("ACCESS_REQUEST_APPROVE")
  end

  def reject?
    approve?
  end
end
