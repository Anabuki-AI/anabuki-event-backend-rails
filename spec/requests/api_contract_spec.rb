require "rails_helper"

RSpec.describe "API contract", type: :request do
  it "preserves the Javalin health contract" do
    get "/health"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq("status" => "ok")
  end

  it "preserves the flat camelCase user creation contract" do
    post "/api/users",
      params: { userName: "Example", email: "example@example.com", password: "secure-password" }.to_json,
      headers: { "CONTENT_TYPE" => "application/json", "ACCEPT" => "application/json" }

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.keys).to contain_exactly("email", "id", "userName")
    expect(response.parsed_body.fetch("userName")).to eq("Example")
  end

  it "reports Google as unconfigured without credentials" do
    get "/api/auth/google/status"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq("configured" => false)
  end

  it "requires an authenticated session for the management queue" do
    get "/api/admin/access-requests"

    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body.fetch("error")).to eq("Authentication is required")
  end
end
