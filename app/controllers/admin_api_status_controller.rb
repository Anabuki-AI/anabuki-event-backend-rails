class AdminApiStatusController < ApplicationController
  def show
    authorize_admin!(:admin_api_status, :show?)
    response.headers["Cache-Control"] = "no-store"
    render json: AdminApiStatus.new.call
  end
end
