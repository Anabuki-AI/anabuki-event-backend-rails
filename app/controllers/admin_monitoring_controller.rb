class AdminMonitoringController < ApplicationController
  def show
    authorize_admin!(:admin_monitoring, :show?)
    response.headers["Cache-Control"] = "no-store"
    render json: AdminMonitoring.new.call
  end
end
