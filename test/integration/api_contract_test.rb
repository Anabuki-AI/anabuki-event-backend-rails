require "test_helper"

class ApiContractTest < ActionDispatch::IntegrationTest
  test "health endpoint preserves the Javalin health contract" do
    get "/health"

    assert_response :success
    assert_equal({ "status" => "ok" }, response.parsed_body)
  end

  test "user creation preserves the flat camelCase request and response contract" do
    post "/api/users", params: { userName: "Example", email: "example@example.com", password: "secure-password" }, as: :json

    assert_response :created, response.body
    assert_equal %w[email id userName], response.parsed_body.keys.sort
    assert_equal "Example", response.parsed_body.fetch("userName")
  end

  test "Google status is available without credentials" do
    get "/api/auth/google/status"

    assert_response :success
    assert_equal({ "configured" => false }, response.parsed_body)
  end

  test "management queue requires an authenticated session" do
    get "/api/admin/access-requests"

    assert_response :unauthorized
    assert_equal "Authentication is required", response.parsed_body.fetch("error")
  end
end
