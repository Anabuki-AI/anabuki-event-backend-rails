Rails.application.routes.draw do
  get "/health", to: "health#show"

  scope "/api" do
    post "/participants", to: "participants#create"
    get "/participants/me", to: "participants#me"
    post "/participants/presence", to: "participants#presence"
    post "/participants/reactions", to: "participants#reactions"
    delete "/participants/session", to: "participants#destroy_session"

    get "/auth/google/status", to: "google_auth#status"
    get "/auth/google/start", to: "google_auth#start"
    get "/auth/google/callback", to: "google_auth#callback"

    get "/admin/auth/session", to: "admin_auth#session"
    get "/admin/api-status", to: "admin_api_status#show"
    get "/admin/questions", to: "admin_questions#index"
    post "/admin/questions", to: "admin_questions#create"
    get "/admin/questions/:id", to: "admin_questions#show"
    put "/admin/questions/:id", to: "admin_questions#update"
    delete "/admin/questions/:id", to: "admin_questions#destroy"
    get "/admin/confidence-multipliers", to: "admin_confidence_multipliers#index"
    patch "/admin/confidence-multipliers/:level", to: "admin_confidence_multipliers#update"
    post "/admin/auth/logout", to: "admin_auth#logout"
    post "/admin/auth/exchange", to: "admin_auth#exchange"
    get "/admin/access-request", to: "access_requests#show"
    post "/admin/access-request", to: "access_requests#create"
    get "/admin/access-requests", to: "access_requests#index"
    post "/admin/access-requests/:id/approve", to: "access_requests#approve"
    post "/admin/access-requests/:id/reject", to: "access_requests#reject"
    get "/admin/allowed-emails", to: "management_accesses#index"
    delete "/admin/allowed-emails/:id", to: "management_accesses#destroy"

    get "/auth/operator/google/status", to: "operator_google_auth#status"
    get "/auth/operator/google/start", to: "operator_google_auth#start"
    get "/auth/operator/google/callback", to: "operator_google_auth#callback"

    get "/operator/auth/session", to: "operator_auth#session"
    post "/operator/auth/logout", to: "operator_auth#logout"
    post "/operator/auth/exchange", to: "operator_auth#exchange"
    get "/operator/access-request", to: "operator_access_requests#show"
    post "/operator/access-request", to: "operator_access_requests#create"

    get "/admin/operator-access-requests", to: "admin_operator_access_requests#index"
    post "/admin/operator-access-requests/:id/approve", to: "admin_operator_access_requests#approve"
    post "/admin/operator-access-requests/:id/reject", to: "admin_operator_access_requests#reject"
  end
end
