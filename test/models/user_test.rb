require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "password is hashed and email is normalized" do
    user = User.create!(user_name: "Example", email: " USER@Example.COM ", password: "secure-password")

    assert_equal "user@example.com", user.email
    assert user.authenticate("secure-password")
    assert_not_equal "secure-password", user.password_digest
  end
end
