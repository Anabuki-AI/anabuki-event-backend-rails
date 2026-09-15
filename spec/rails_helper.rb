ENV["RAILS_ENV"] ||= "test"
require File.expand_path("../../config/environment", __FILE__)
abort("The Rails environment is running in production mode!") if Rails.env.production?
require "rspec/rails"
require_relative "spec_helper"

Dir[Rails.root.join("spec/support/**/*.rb")].sort.each { |file| require file }

# Multi-DB: the operator test database is created and migrated before
# maintain_test_schema!, which validates every configured database.
# Creation goes through a raw PG connection because
# ActiveRecord::Tasks::DatabaseTasks.create would register its "postgres"
# maintenance connection pool and re-point the primary database in this
# process. The migration runs inside with_temporary_connection so the
# primary pool is restored afterwards.
operator_config = ActiveRecord::Base.configurations.configs_for(env_name: "test", name: "operator")
if operator_config
  hash = operator_config.configuration_hash
  server = PG.connect(
    host: hash[:host], port: hash[:port] || 5432,
    user: hash[:username], password: hash[:password],
    dbname: "postgres"
  )
  exists = server.exec("SELECT 1 FROM pg_database WHERE datname = $1", [ hash.fetch(:database) ]).ntuples > 0
  server.exec("CREATE DATABASE #{PG::Connection.quote_ident(hash.fetch(:database))}") unless exists
  server.close

  ActiveRecord::Tasks::DatabaseTasks.with_temporary_connection(operator_config) do
    ActiveRecord::Tasks::DatabaseTasks.migrate
  end
end

begin
  ActiveRecord::Migration.maintain_test_schema!
rescue ActiveRecord::PendingMigrationError => e
  abort e.to_s.strip
end

RSpec.configure do |config|
  config.fixture_paths = [ Rails.root.join("spec/fixtures") ]
  config.use_transactional_fixtures = true
  config.infer_spec_type_from_file_location!
  config.filter_rails_from_backtrace!
end
