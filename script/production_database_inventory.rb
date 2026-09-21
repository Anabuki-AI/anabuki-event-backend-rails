# Read-only production database preflight.
#
# This script intentionally queries information_schema only. It must not create
# databases/tables, write rows, acquire an application lock, or change roles.

require "active_record"

# Keep this list aligned with the tables created by db/migrate and Que's
# migration. A public table outside this set is not safe to treat as an
# application-managed production database.
EXPECTED_PUBLIC_TABLES = %w[
  active_storage_attachments
  active_storage_blobs
  active_storage_variant_records
  admin_access_requests
  admin_device_sessions
  admin_identities
  admin_oauth_states
  ar_internal_metadata
  audit_logs
  confidence_multipliers
  operator_device_sessions
  operator_identities
  operator_oauth_states
  participant_answers
  participant_quiz_confidence_selections
  participant_sessions
  participants
  que_jobs
  que_lockers
  que_values
  questions
  quiz_sessions
  schema_migrations
].freeze

begin
  rows = ActiveRecord::Base.connection.select_all(<<~SQL)
    SELECT table_schema, table_name
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_type = 'BASE TABLE'
    ORDER BY table_name
  SQL

  tables = rows.map { |row| row.fetch("table_name") }
  schema_migrations_present = tables.include?("schema_migrations")

  puts "public schema base table count: #{tables.length}"
  tables.each { |table_name| puts "public table: #{table_name}" }
  puts "schema_migrations: #{schema_migrations_present ? "present" : "absent"}"

  if !schema_migrations_present && tables.empty?
    # The caller may safely distinguish this from a connection/configuration
    # error and decide whether an explicitly confirmed initial migration is
    # appropriate.
    exit 10
  end

  if !schema_migrations_present
    # A table without Rails' migration ledger is an unknown/partial state. It
    # must never be treated as a fresh database.
    exit 21
  end

  unexpected_tables = tables - EXPECTED_PUBLIC_TABLES
  exit 22 unless unexpected_tables.empty?

  exit 0
rescue StandardError => error
  # The workflow captures stderr and deliberately reports only this stable
  # classification. Do not print the exception message: adapter errors can
  # contain connection URLs or other sensitive configuration.
  warn "production database preflight failed: #{error.class.name}"
  exit 20
end
