require "rails_helper"
require "digest"
require "securerandom"

RSpec.describe "Participant user registration", type: :request do
  let(:origin) { "https://event.example" }
  let(:payload) do
    {
      uuid: "2b4f2c6f-8a33-4e71-bc0f-4c6d3a91f201",
      userName: "参加者01",
      gender: "男性",
      ageGroup: "20代",
      school: "専門学校穴吹ITビジネスカレッジ",
      department: "AIテクノロジー学科",
      studentType: "STUDENT_SHOULD_BE_IGNORED",
      agreedTerms: true
    }
  end

  around do |example|
    with_env(
      "PUBLIC_BASE_URL" => origin,
      "ADMIN_FRONTEND_URL" => "#{origin}/admin"
    ) do
      host! "event.example"
      https!
      example.run
    end
  end

  def post_registration(params = payload, headers: { "Origin" => origin })
    post "/api/users", params:, headers:, as: :json
  end

  def clear_participant_cookies
    [ ParticipantAuth::DEVICE_COOKIE, ParticipantAuth::SESSION_COOKIE ].each { |name| cookies.delete(name) }
  end

  it "creates a participant with every Issue field and returns the public contract" do
    expect { post_registration }.to change(ParticipantIdentity, :count).by(1)

    expect(response).to have_http_status(:created)
    body = response.parsed_body
    expect(body.keys).to contain_exactly("uuid", "userName", "message")
    expect(body.fetch("uuid")).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i)
    expect(body.fetch("userName")).to eq("参加者01")
    expect(body.fetch("message")).to be_a(String)

    participant = ParticipantIdentity.find_by!(uuid: body.fetch("uuid"))
    expect(participant.user_name).to eq("参加者01")
    expect(participant.gender).to eq("男性")
    expect(participant.age_group).to eq("20代")
    expect(participant.school).to eq("専門学校穴吹ITビジネスカレッジ")
    expect(participant.department).to eq("AIテクノロジー学科")
    expect(participant.agreed_terms).to be(true)
    expect(participant.attributes).not_to have_key("student_type")
  end

  it "ignores a client supplied uuid and studentType in the response while preserving the generated uuid" do
    post_registration

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.fetch("uuid")).not_to eq(payload.fetch(:uuid))
    expect(response.parsed_body.fetch("userName")).to eq(payload.fetch(:userName))
    expect(ParticipantIdentity.sole.uuid).to eq(response.parsed_body.fetch("uuid"))
  end

  it "returns the current participant for a bodyless request with an existing session" do
    post_registration
    first_response = response.parsed_body

    post "/api/users", headers: { "Origin" => origin }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq(first_response)
    expect(ParticipantIdentity.count).to eq(1)
    expect(ParticipantDeviceSession.count).to eq(1)
  end

  it "uses secure, hashed, fixed-duration participant session cookies" do
    post_registration

    cookie_header = response.headers.fetch("Set-Cookie").to_s.downcase
    expect(cookie_header).to include("#{ParticipantAuth::DEVICE_COOKIE}=".downcase, "#{ParticipantAuth::SESSION_COOKIE}=".downcase)
    expect(cookie_header).to include("httponly", "secure", "samesite=lax", "path=/")

    device = cookies[ParticipantAuth::DEVICE_COOKIE]
    session_key = cookies[ParticipantAuth::SESSION_COOKIE]
    session = ParticipantDeviceSession.sole
    original_expiry = session.expires_at

    expect(session.device_id_hash).to eq(Digest::SHA256.digest(device))
    expect(session.session_key_hash).to eq(Digest::SHA256.digest(session_key))
    expect(session.device_id_hash).not_to eq(device)
    expect(session.session_key_hash).not_to eq(session_key)
    expect(session.expires_at).to be_within(2.seconds).of(3.hours.from_now)

    post "/api/users", headers: { "Origin" => origin }

    expect(response).to have_http_status(:ok)
    expect(session.reload.expires_at).to eq(original_expiry)
  end

  it "does not treat expired, wrong-device, or wrong-session cookies as authenticated" do
    post_registration
    session = ParticipantDeviceSession.sole
    device = cookies[ParticipantAuth::DEVICE_COOKIE]

    session.update!(expires_at: 1.second.ago)
    post "/api/users", headers: { "Origin" => origin }
    expect(response).to have_http_status(:unprocessable_content)

    session.update!(expires_at: 3.hours.from_now)
    cookies[ParticipantAuth::DEVICE_COOKIE] = SecureRandom.urlsafe_base64(32, false)
    post "/api/users", headers: { "Origin" => origin }
    expect(response).to have_http_status(:unprocessable_content)

    cookies[ParticipantAuth::DEVICE_COOKIE] = device
    cookies[ParticipantAuth::SESSION_COOKIE] = SecureRandom.urlsafe_base64(32, false)
    post "/api/users", headers: { "Origin" => origin }
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "rolls back registration when participant session creation fails" do
    auth = instance_double(ParticipantAuth, current_identity: nil)
    allow(auth).to receive(:establish_session!).and_raise(ParticipantAuth::SessionCreationError, "database failure")
    allow(ParticipantAuth).to receive(:new).and_return(auth)

    expect { post_registration }.not_to change(ParticipantIdentity, :count)

    expect(response).to have_http_status(:internal_server_error)
    expect(response.parsed_body).to eq("error" => "Participant session could not be created")
  end

  it "rejects an untrusted Origin" do
    post_registration(headers: { "Origin" => "https://evil.example" })

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body).to eq("error" => "Origin is not allowed")
    expect(ParticipantIdentity.count).to eq(0)
  end

  it "keeps every non-POST method on /api/users unavailable" do
    [ :get, :put, :patch, :delete ].each do |http_method|
      public_send(http_method, "/api/users", headers: { "Origin" => origin })

      expect(response).to have_http_status(:not_found), "expected #{http_method.to_s.upcase} /api/users to be 404"
    end
  end

  it "normalizes the nickname to NFC and removes surrounding ordinary whitespace" do
    post_registration(payload.merge(userName: "  は\u3099なな  "))

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.fetch("userName")).to eq("ばなな")
    expect(ParticipantIdentity.sole.user_name).to eq("ばなな")
  end

  it "allows Japanese, ASCII punctuation, case differences, and full-width differences" do
    [ "あいう", "ユーザー01", "name!", "NAME!", "ｎａｍｅ" ].each do |user_name|
      clear_participant_cookies
      post_registration(payload.merge(userName: user_name))
      expect(response).to have_http_status(:created), "expected #{user_name.inspect} to be accepted"
    end
  end

  it "rejects an unavailable nickname with one unified error" do
    post_registration(payload.merge(userName: "taken-name"))
    clear_participant_cookies
    post_registration(payload.merge(userName: "taken-name"))

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body).to eq("error" => "このユーザー名は使用できません")
    expect(ParticipantIdentity.count).to eq(1)
  end

  it "rejects invalid nickname forms" do
    [ "", "ab", "a" * 21, "🙂abc", "abc\u202Edef", "abc\u0000def" ].each do |user_name|
      post_registration(payload.merge(userName: user_name))

      expect(response).to have_http_status(:unprocessable_content), "expected #{user_name.inspect} to be rejected"
      expect(response.parsed_body).to eq("error" => "このユーザー名は使用できません")
    end
  end

  it "rejects values other than boolean true for agreedTerms" do
    [ false, "true", 1, nil ].each do |agreed_terms|
      post_registration(payload.merge(agreedTerms: agreed_terms))

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to eq("error" => "利用規約への同意が必要です")
    end
  end

  it "requires gender and ageGroup" do
    post_registration(payload.except(:gender))
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.fetch("error")).to include("Gender")

    post_registration(payload.except(:ageGroup))
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.fetch("error")).to include("Age group")
  end

  it "rejects undefined gender and age group values" do
    post_registration(payload.merge(gender: "その他"))
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.fetch("error")).to include("Gender")

    post_registration(payload.merge(ageGroup: "70代"))
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.fetch("error")).to include("Age group")
  end

  it "stores blank school and department values as null and clears department for non-Anabuki schools" do
    post_registration(payload.merge(school: "  ", department: "  "))
    expect(response).to have_http_status(:created)
    expect(ParticipantIdentity.sole.school).to be_nil
    expect(ParticipantIdentity.sole.department).to be_nil

    clear_participant_cookies
    post_registration(payload.merge(userName: "other-school", school: "Other School", department: "Department"))
    expect(response).to have_http_status(:created)
    expect(ParticipantIdentity.order(:id).last.department).to be_nil
  end

  it "rejects an unknown department for an Anabuki school" do
    post_registration(payload.merge(department: "グラフィックデザイン学科"))

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.fetch("error")).to include("Department")
  end

  it "requires a department for an Anabuki school" do
    post_registration(payload.merge(department: nil))

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.fetch("error")).to include("Department")
  end

  it "rejects school and department values longer than 100 characters" do
    post_registration(payload.merge(school: "あ" * 101))

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.fetch("error")).to include("School")

    post_registration(payload.merge(department: "あ" * 101))
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.fetch("error")).to include("Department")
  end

  it "returns the existing error shape for malformed JSON" do
    post "/api/users", params: "{", headers: { "CONTENT_TYPE" => "application/json", "Origin" => origin }

    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body).to eq("error" => "Invalid request")
  end

  it "enforces UUID uniqueness in PostgreSQL" do
    now = Time.current
    attributes = {
      uuid: SecureRandom.uuid,
      user_name: "db-unique-name",
      gender: "男性",
      age_group: "20代",
      agreed_terms: true,
      created_at: now,
      updated_at: now
    }
    ParticipantIdentity.insert_all!([ attributes ])

    expect {
      ParticipantIdentity.insert_all!([ attributes.merge(user_name: "another-name") ])
    }.to raise_error(ActiveRecord::RecordNotUnique)
  end
end
