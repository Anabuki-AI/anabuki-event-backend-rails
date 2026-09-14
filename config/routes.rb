Rails.application.routes.draw do
  get "/health", to: "health#show"

  scope "/api" do
    get "/auth/google/status", to: "google_auth#status"
    get "/auth/google/start", to: "google_auth#start"
    get "/auth/google/callback", to: "google_auth#callback"

    get "/admin/auth/session", to: "admin_auth#session"
    get "/admin/api-status", to: "admin_api_status#show"
    post "/admin/auth/logout", to: "admin_auth#logout"
    post "/admin/auth/exchange", to: "admin_auth#exchange"
    get "/admin/access-request", to: "access_requests#show"
    post "/admin/access-request", to: "access_requests#create"
    get "/admin/access-requests", to: "access_requests#index"
    post "/admin/access-requests/:id/approve", to: "access_requests#approve"
    post "/admin/access-requests/:id/reject", to: "access_requests#reject"
    get "/admin/allowed-emails", to: "management_accesses#index"
    delete "/admin/allowed-emails/:id", to: "management_accesses#destroy"
  end
end
