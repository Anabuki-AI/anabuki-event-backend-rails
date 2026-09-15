# Authorizes admin-portal administration of operator access requests.
# pundit_user is the AdminAuth session, so operator requests are gated by the
# same ACCESS_REQUEST_APPROVE permission as admin ones.
class Operator::AccessRequestPolicy < ApplicationPolicy
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
