require "rails_helper"

RSpec.describe "Admin authorization policies" do
  it "allows only management and environment sessions to approve or reject requests" do
    applicant = session("APPLICANT", [])
    manager = session("MANAGEMENT_ACCESS", %w[MANAGEMENT_PAGE_VIEW ACCESS_REQUEST_APPROVE])
    environment = session(
      "ENVIRONMENT_ACCESS",
      %w[MANAGEMENT_PAGE_VIEW ACCESS_REQUEST_APPROVE MANAGEMENT_ACCESS_REVOKE]
    )

    expect(AdminAccessRequestPolicy.new(applicant, AdminAccessRequest)).not_to be_index
    expect(AdminAccessRequestPolicy.new(applicant, AdminAccessRequest)).not_to be_approve
    expect(AdminAccessRequestPolicy.new(applicant, AdminAccessRequest)).not_to be_reject

    expect(AdminAccessRequestPolicy.new(manager, AdminAccessRequest)).to be_index
    expect(AdminAccessRequestPolicy.new(manager, AdminAccessRequest)).to be_approve
    expect(AdminAccessRequestPolicy.new(manager, AdminAccessRequest)).to be_reject

    expect(AdminAccessRequestPolicy.new(environment, AdminAccessRequest)).to be_approve
  end

  it "allows management and environment sessions to revoke only other identities" do
    manager_identity = identity
    environment_identity = identity
    other_identity = identity
    manager = session(
      "MANAGEMENT_ACCESS",
      %w[MANAGEMENT_PAGE_VIEW ACCESS_REQUEST_APPROVE MANAGEMENT_ACCESS_REVOKE],
      identity: manager_identity
    )
    environment = session(
      "ENVIRONMENT_ACCESS",
      %w[MANAGEMENT_PAGE_VIEW ACCESS_REQUEST_APPROVE MANAGEMENT_ACCESS_REVOKE],
      identity: environment_identity
    )

    expect(AdminIdentityPolicy.new(manager, AdminIdentity)).to be_index
    expect(AdminIdentityPolicy.new(manager, AdminIdentity)).to be_destroy
    expect(AdminIdentityPolicy.new(manager, other_identity)).to be_destroy
    expect(AdminIdentityPolicy.new(manager, manager_identity)).not_to be_destroy

    expect(AdminIdentityPolicy.new(environment, AdminIdentity)).to be_index
    expect(AdminIdentityPolicy.new(environment, other_identity)).to be_destroy
    expect(AdminIdentityPolicy.new(environment, environment_identity)).not_to be_destroy
  end

  private

  def session(source, permissions, identity: nil)
    AdminAuth::Session.new(nil, identity, source, permissions)
  end

  def identity
    suffix = SecureRandom.uuid
    AdminIdentity.create!(email: "policy-#{suffix}@example.com", google_sub: "policy-sub-#{suffix}")
  end
end
