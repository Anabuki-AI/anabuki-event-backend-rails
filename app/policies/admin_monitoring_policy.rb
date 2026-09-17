class AdminMonitoringPolicy < ApplicationPolicy
  def show?
    allowed?("MANAGEMENT_PAGE_VIEW")
  end
end
