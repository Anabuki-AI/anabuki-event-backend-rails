class ManagementAccessesController < ApplicationController
  def index
    render json: admin_auth.management_accesses!
  end

  def destroy
    require_same_origin!
    admin_auth.deactivate_management_access!(params[:id])
    head :no_content
  rescue ArgumentError
    render_error("identityId must be a UUID", :bad_request)
  end
end
