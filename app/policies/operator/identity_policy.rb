# Admin-portal authorization for directly managing already authenticated
# operator identities. This is intentionally independent of access requests.
class Operator::IdentityPolicy < ApplicationPolicy
  def index?
    allowed?("MANAGEMENT_PAGE_VIEW")
  end

  def update?
    index?
  end
end
