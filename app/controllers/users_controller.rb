class UsersController < ApplicationController
  def show
    render json: user_json(User.find(params[:id]))
  end

  def create
    user = User.new(user_params)
    if user.save
      render json: user_json(user), status: :created
    elsif user.errors.of_kind?(:email, :taken)
      render_error("Email is already registered", :conflict)
    else
      render_error(user.errors.full_messages.to_sentence, :bad_request)
    end
  rescue ActiveRecord::RecordNotUnique
    render_error("Email is already registered", :conflict)
  end

  private

  # The established Nuxt API sends a flat camelCase JSON object, rather than a
  # Rails-namespaced `user` object. Keep that contract during the migration.
  def user_params
    # Action Controller may wrap JSON in `user` based on this controller name;
    # accept either representation while keeping the external API flat.
    payload = params[:user].presence || params
    {
      user_name: payload[:userName],
      email: payload[:email],
      password: payload[:password]
    }
  end

  def user_json(user)
    { id: user.id, userName: user.user_name, email: user.email }
  end
end
