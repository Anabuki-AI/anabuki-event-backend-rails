class AdminIdentityPolicy < ApplicationPolicy
  def index?
    allowed?("MANAGEMENT_PAGE_VIEW")
  end

  def destroy?
    return allowed?("MANAGEMENT_ACCESS_REVOKE") if record == AdminIdentity

    allowed?("MANAGEMENT_ACCESS_REVOKE") && record.id != user.identity.id
  end
end
