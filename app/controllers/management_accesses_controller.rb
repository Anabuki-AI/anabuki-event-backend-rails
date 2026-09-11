class ManagementAccessesController < ApplicationController
  def index
    authorize_admin!(AdminIdentity, :index?)
    render json: admin_auth.management_accesses!
  end

  def destroy
    require_same_origin!
    authorize_admin!(AdminIdentity, :destroy?)
    identity = AdminIdentity.find(params[:id])
    authorize_admin!(identity, :destroy?)
    admin_auth.deactivate_management_access!(identity.id)
    head :no_content
  rescue ArgumentError
    render_error("identityId must be a UUID", :bad_request)
  end
end
