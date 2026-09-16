class ConfidenceMultiplierPolicy < ApplicationPolicy
  def index? = allowed?("MANAGEMENT_PAGE_VIEW")
  def update? = index?
end
