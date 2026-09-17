require "rails_helper"

RSpec.describe "API contract", type: :request do
  it "preserves the Javalin health contract" do
    get "/health"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq("status" => "ok")
  end

  it "serves the health contract through the API prefix" do
    get "/api/health"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq("status" => "ok")
  end

  it "requires an authenticated session for the management queue" do
    get "/api/admin/access-requests"

    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body.fetch("error")).to eq("Authentication is required")
  end
end
