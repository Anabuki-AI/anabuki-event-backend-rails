require "rails_helper"

RSpec.describe "Event operator API authorization", type: :request do
  around do |example|
    host! "localhost"
    example.run
  end

  before do
    Operator::DeviceSession.delete_all
    Operator::Identity.delete_all
  end

  it "allows an admin management session without an operator session" do
    authenticate_admin

    get "/api/admin/questions"
    expect(response).to have_http_status(:ok)

    post "/api/admin/questions", params: question_payload, as: :json
    expect(response).to have_http_status(:created)
  end

  it "allows an operator manager session to use question and multiplier APIs" do
    authenticate_operator(manager_enabled: true)

    get "/api/admin/questions"
    expect(response).to have_http_status(:ok)

    post "/api/admin/questions", params: question_payload, as: :json
    expect(response).to have_http_status(:created)

    get "/api/admin/confidence-multipliers"
    expect(response).to have_http_status(:ok)
  end

  it "does not allow an operator applicant session to use event-operation APIs" do
    authenticate_operator(manager_enabled: false)

    get "/api/admin/questions"
    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body).to eq("error" => "Authentication is required")
  end

  private

  def authenticate_admin
    identity = AdminIdentity.create!(email: "admin-#{SecureRandom.uuid}@example.com", google_sub: "admin-#{SecureRandom.uuid}", admin_enabled: true)
    device = SecureRandom.urlsafe_base64(32, false)
    session_key = SecureRandom.urlsafe_base64(32, false)
    AdminDeviceSession.create!(
      admin_identity: identity,
      device_id_hash: Digest::SHA256.digest(device),
      session_key_hash: Digest::SHA256.digest(session_key),
      email: identity.email,
      google_sub: identity.google_sub,
      access_source: "MANAGEMENT_ACCESS",
      expires_at: 1.hour.from_now,
      last_seen_at: Time.current
    )
    cookies[AdminAuth::DEVICE_COOKIE] = device
    cookies[AdminAuth::SESSION_COOKIE] = session_key
  end

  def authenticate_operator(manager_enabled:)
    identity = Operator::Identity.create!(email: "operator-#{SecureRandom.uuid}@example.com", google_sub: "operator-#{SecureRandom.uuid}", manager_enabled:)
    device = SecureRandom.urlsafe_base64(32, false)
    session_key = SecureRandom.urlsafe_base64(32, false)
    Operator::DeviceSession.create!(
      operator_identity: identity,
      device_id_hash: Digest::SHA256.digest(device),
      session_key_hash: Digest::SHA256.digest(session_key),
      email: identity.email,
      google_sub: identity.google_sub,
      access_source: manager_enabled ? "MANAGER" : "APPLICANT",
      expires_at: 1.hour.from_now,
      last_seen_at: Time.current
    )
    cookies[OperatorAuth::DEVICE_COOKIE] = device
    cookies[manager_enabled ? OperatorAuth::SESSION_COOKIE : OperatorAuth::APPLICANT_SESSION_COOKIE] = session_key
  end

  def question_payload
    {
      questionText: "Question", choiceA: "A", choiceB: "B", choiceC: "C", choiceD: "D", correctAnswer: "A"
    }
  end
end
