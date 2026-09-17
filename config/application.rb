require_relative "boot"

require "rails/all"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module AnabukiEventBackendRails
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # Only loads a smaller set of middleware suitable for API only apps.
    # Middleware like session, flash, cookies can be added back manually.
    # Skip views, helpers and assets when generating a new resource.
    config.api_only = true

    # Que stores Active Job payloads in PostgreSQL and processes them in a separate worker.
    config.active_job.queue_adapter = :que
    config.active_record.schema_format = :sql
    # Operator emails use Rails 8.1 Active Record Encryption. Never allow a
    # plaintext fallback when encrypted data is expected.
    config.active_record.encryption.support_unencrypted_data = false

    # API-only applications omit cookie middleware by default. Admin sessions are
    # HttpOnly, SameSite=Lax cookies, never Rails server-side browser sessions.
    config.middleware.use ActionDispatch::Cookies
  end
end
