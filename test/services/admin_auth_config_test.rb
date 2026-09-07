require "test_helper"

class AdminAuthConfigTest < ActiveSupport::TestCase
  test "only exact public origins are accepted" do
    with_env("PUBLIC_BASE_URL" => "https://event.example", "ADMIN_FRONTEND_URL" => "https://event.example/admin") do
      config = AdminAuthConfig.new
      assert config.allowed_origin?("https://event.example")
      assert_not config.allowed_origin?("https://attacker.example")
      assert_not config.allowed_origin?("http://event.example")
    end
  end

  private

  def with_env(values)
    old = values.to_h { |key, _value| [ key, ENV[key] ] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    old.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
