# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Google management-access lifecycle", type: :request do
  include GoogleOauthHelpers

  around do |example|
    with_env(oauth_env) { example.run }
  end

  it "runs applicant request, independent manager approval, poll, exchange, and logout through real cookies and records" do
    applicant = new_browser
    google_login(applicant, email: "applicant@example.com", sub: "applicant-sub", code: "applicant-login")

    applicant.post "/api/admin/access-request", headers: same_origin_headers
    expect(applicant.response).to have_http_status(:created)
    created = response_json(applicant)
    expect(created).to include("email" => "applicant@example.com", "status" => "PENDING")
    request_id = created.fetch("id")
    access_request = AdminAccessRequest.find(request_id)

    manager_identity = AdminIdentity.create!(
      email: "manager@example.com",
      google_sub: "manager-sub",
      admin_enabled: true
    )
    manager = new_browser
    google_login(manager, email: manager_identity.email, sub: manager_identity.google_sub, code: "manager-login")

    manager.get "/api/admin/access-requests"
    expect(manager.response).to have_http_status(:ok)
    expect(response_json(manager)).to include(a_hash_including("id" => request_id, "status" => "PENDING"))

    manager.post "/api/admin/access-requests/#{request_id}/approve", headers: same_origin_headers
    expect(manager.response).to have_http_status(:ok)
    expect(response_json(manager)).to include("id" => request_id, "status" => "APPROVED")

    applicant.get "/api/admin/access-request"
    expect(applicant.response).to have_http_status(:ok)
    polled = response_json(applicant)
    expect(polled).to include("id" => request_id, "status" => "APPROVED")
    expect(polled).not_to have_key("applicantDeviceIdHash")
    expect(polled).not_to have_key("applicantSessionKeyHash")
    expect(applicant.response.body).not_to include(access_request.applicant_device_id_hash.unpack1("H*"))
    expect(applicant.response.body).not_to include(access_request.applicant_session_key_hash.unpack1("H*"))

    applicant.post "/api/admin/auth/exchange", headers: same_origin_headers
    expect(applicant.response).to have_http_status(:no_content)
    expect(applicant.cookies[AdminAuth::APPLICANT_SESSION_COOKIE]).to be_blank
    expect(applicant.cookies[AdminAuth::SESSION_COOKIE]).to be_present

    applicant.get "/api/admin/auth/session"
    expect(applicant.response).to have_http_status(:ok)
    expect(response_json(applicant)).to include(
      "accessSource" => "MANAGEMENT_ACCESS",
      "permissions" => %w[MANAGEMENT_PAGE_VIEW ACCESS_REQUEST_APPROVE]
    )
    expect(applicant.response.body).not_to include(access_request.applicant_device_id_hash.unpack1("H*"))
    expect(applicant.response.body).not_to include(access_request.applicant_session_key_hash.unpack1("H*"))

    applicant.post "/api/admin/auth/logout", headers: same_origin_headers
    expect(applicant.response).to have_http_status(:no_content)
    applicant.get "/api/admin/auth/session"
    expect(applicant.response).to have_http_status(:unauthorized)
    expect(response_json(applicant)).to eq("error" => "Authentication is required")
  end

  it "forbids an applicant from reading the management approval queue" do
    applicant = new_browser
    google_login(applicant, email: "applicant@example.com", sub: "applicant-sub", code: "applicant-login")

    applicant.get "/api/admin/access-requests"

    expect(applicant.response).to have_http_status(:forbidden)
    expect(response_json(applicant)).to eq("error" => "Management page access is required")
  end

  it "allows only an environment-access session to revoke another management identity" do
    revocable_identity = AdminIdentity.create!(
      email: "other-manager@example.com",
      google_sub: "other-manager-sub",
      admin_enabled: true
    )
    manager_identity = AdminIdentity.create!(
      email: "manager@example.com",
      google_sub: "manager-sub",
      admin_enabled: true
    )
    manager = new_browser
    google_login(manager, email: manager_identity.email, sub: manager_identity.google_sub, code: "manager-login")

    manager.delete "/api/admin/allowed-emails/#{revocable_identity.id}", headers: same_origin_headers
    expect(manager.response).to have_http_status(:forbidden)
    expect(response_json(manager)).to eq("error" => "Required permission is missing")
    expect(revocable_identity.reload).to be_admin_enabled

    environment = new_browser
    google_login(
      environment,
      email: "environment@example.com",
      sub: "environment-sub",
      code: "environment-login"
    )

    environment.delete "/api/admin/allowed-emails/#{revocable_identity.id}", headers: same_origin_headers
    expect(environment.response).to have_http_status(:no_content)
    expect(revocable_identity.reload).not_to be_admin_enabled
    expect(revocable_identity.revoked_at).to be_present
  end

  it "returns REJECTED to the applicant and refuses an exchange after a manager rejects the request" do
    applicant = new_browser
    google_login(applicant, email: "applicant@example.com", sub: "applicant-sub", code: "applicant-login")
    applicant.post "/api/admin/access-request", headers: same_origin_headers
    request_id = response_json(applicant).fetch("id")

    manager_identity = AdminIdentity.create!(
      email: "manager@example.com",
      google_sub: "manager-sub",
      admin_enabled: true
    )
    manager = new_browser
    google_login(manager, email: manager_identity.email, sub: manager_identity.google_sub, code: "manager-login")
    manager.post "/api/admin/access-requests/#{request_id}/reject", headers: same_origin_headers
    expect(manager.response).to have_http_status(:ok)
    expect(response_json(manager)).to include("status" => "REJECTED")

    applicant.get "/api/admin/access-request"
    expect(applicant.response).to have_http_status(:ok)
    expect(response_json(applicant)).to include("id" => request_id, "status" => "REJECTED")

    applicant.post "/api/admin/auth/exchange", headers: same_origin_headers
    expect(applicant.response).to have_http_status(:forbidden)
    expect(response_json(applicant)).to eq("error" => "The approved applicant session cannot be exchanged")
    expect(applicant.cookies[AdminAuth::APPLICANT_SESSION_COOKIE]).to be_present
  end

  it "cancels a pending request on logout, rejects use after logout, and does not revive it on relogin" do
    applicant = new_browser
    google_login(applicant, email: "applicant@example.com", sub: "applicant-sub", code: "first-login")
    applicant.post "/api/admin/access-request", headers: same_origin_headers
    access_request = AdminAccessRequest.find(response_json(applicant).fetch("id"))

    applicant.post "/api/admin/auth/logout", headers: same_origin_headers
    expect(applicant.response).to have_http_status(:no_content)
    expect(access_request.reload).to be_cancelled
    expect(access_request.cancelled_at).to be_present
    expect(access_request.cancellation_reason).to eq("APPLICANT_LOGGED_OUT")

    applicant.get "/api/admin/auth/session"
    expect(applicant.response).to have_http_status(:unauthorized)
    applicant.post "/api/admin/access-request", headers: same_origin_headers
    expect(applicant.response).to have_http_status(:unauthorized)

    google_login(applicant, email: "applicant@example.com", sub: "applicant-sub", code: "relogin")
    applicant.get "/api/admin/access-request"
    expect(applicant.response).to have_http_status(:no_content)
    expect(access_request.reload).to be_cancelled
    expect(access_request.status).to eq("cancelled")
  end

  it "returns CANCELLED in uppercase when the server invalidates a still-present applicant cookie pair" do
    applicant = new_browser
    google_login(applicant, email: "applicant@example.com", sub: "applicant-sub", code: "applicant-login")
    applicant.post "/api/admin/access-request", headers: same_origin_headers
    access_request = AdminAccessRequest.find(response_json(applicant).fetch("id"))

    access_request.applicant_session.update!(revoked_at: Time.current)
    applicant.get "/api/admin/access-request"

    expect(applicant.response).to have_http_status(:ok)
    expect(response_json(applicant)).to include("id" => access_request.id, "status" => "CANCELLED")
    expect(access_request.reload).to be_cancelled
    expect(access_request.cancellation_reason).to eq("APPLICANT_SESSION_REVOKED")
  end

  it "rejects a forged device/session cookie pair without changing the genuine applicant request" do
    applicant = new_browser
    google_login(applicant, email: "applicant@example.com", sub: "applicant-sub", code: "applicant-login")
    applicant.post "/api/admin/access-request", headers: same_origin_headers
    access_request = AdminAccessRequest.find(response_json(applicant).fetch("id"))

    another_browser = new_browser
    google_login(another_browser, email: "other@example.com", sub: "other-sub", code: "other-login")
    another_browser.cookies[AdminAuth::DEVICE_COOKIE] = applicant.cookies[AdminAuth::DEVICE_COOKIE]

    another_browser.get "/api/admin/auth/session"
    expect(another_browser.response).to have_http_status(:unauthorized)
    another_browser.post "/api/admin/access-request", headers: same_origin_headers
    expect(another_browser.response).to have_http_status(:unauthorized)
    expect(access_request.reload).to be_pending
  end
end
