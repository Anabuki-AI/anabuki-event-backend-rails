class QuestionPolicy < ApplicationPolicy
  def index? = allowed?("MANAGEMENT_PAGE_VIEW")
  def show? = index?
  def create? = index?
  def update? = index?
  def destroy? = index?
end
