# Sentry is intentionally inert without a DSN and never sends from development/test.
Sentry.init do |config|
  config.dsn = ENV["SENTRY_DSN"]
  config.environment = ENV.fetch("SENTRY_ENVIRONMENT", Rails.env)
  config.release = ENV["SENTRY_RELEASE"].presence || ENV["GIT_COMMIT"].presence
  config.enabled_environments = ENV.fetch("SENTRY_ENABLED_ENVIRONMENTS", "production").split(",").map(&:strip).reject(&:empty?) - %w[development test]
  config.enabled_environments = [] if Rails.env.development? || Rails.env.test?
  config.send_default_pii = false
  config.rails.report_rescued_exceptions = true
  config.rails.active_job_report_on_retry_error = true

  # Keep queue payloads and request data out of error events unless explicitly
  # allowed later. Que's Active Job integration still reports exceptions and
  # includes job identity, but not serialized arguments.
  config.data_collection.user_info = false
  config.data_collection.cookies.mode = :off
  config.data_collection.http_bodies = []
  config.data_collection.url_query_params.mode = :off
  config.data_collection.database_query_data = false
  config.data_collection.queues = false
  config.data_collection.http_headers.request.mode = :deny_list
  config.data_collection.http_headers.request.terms = %w[authorization cookie set-cookie x-api-key x-auth-token x-csrf-token]
  config.data_collection.http_headers.response.mode = :deny_list
  config.data_collection.http_headers.response.terms = %w[authorization cookie set-cookie x-api-key x-auth-token x-csrf-token]
end
