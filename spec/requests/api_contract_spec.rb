require "rails_helper"

RSpec.describe "API contract", type: :request do
  it "preserves the Javalin health contract" do
    get "/health"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq("status" => "ok")
  end

  it "does not expose the retired password registration fields" do
    post "/api/users",
      params: { userName: "Example", email: "example@example.com", password: "secure-password" },
      as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body).to eq("error" => "利用規約への同意が必要です")
  end

  it "does not expose the obsolete user lookup" do
    get "/api/users/1", as: :json

    expect(response).to have_http_status(:not_found)
  end

  it "requires an authenticated session for the management queue" do
    get "/api/admin/access-requests"

    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body.fetch("error")).to eq("Authentication is required")
  end
end
