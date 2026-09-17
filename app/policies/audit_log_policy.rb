class AuditLogPolicy < ApplicationPolicy
  def index? = allowed?("MANAGEMENT_PAGE_VIEW")
end
