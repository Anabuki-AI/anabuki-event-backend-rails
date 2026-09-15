class OperatorGoogleAuthController < ApplicationController
  def start
    redirect_to operator_auth.begin_oauth!, allow_other_host: true
  end

  def callback
    redirect_to operator_auth.complete_oauth!(code: params[:code], state: params[:state]), allow_other_host: true
  end
end
