# Read-only production schema audit.
#
# This script uses the pg gem directly so Rails application boot and its
# broader production secret configuration are not required. The connection is
# placed in a read-only transaction and only metadata queries (plus the
# requested schema_migrations version lookup) are executed.

require "pg"

MAX_OUTPUT_LENGTH = 500


def safe_value(value, limit: MAX_OUTPUT_LENGTH)
  normalized = value.to_s.gsub(/\s+/, " ").strip
  return normalized if normalized.length <= limit

  "#{normalized[0, limit - 1]}…"
end


def table_exists?(connection, table_name)
  result = connection.exec_params(<<~SQL, [ table_name ])
    SELECT EXISTS (
      SELECT 1
      FROM information_schema.tables
      WHERE table_schema = 'public'
        AND table_name = $1
        AND table_type = 'BASE TABLE'
    ) AS present
  SQL

  result[0]["present"] == "t"
end


def column_metadata(connection, table_name, column_name)
  result = connection.exec_params(<<~SQL, [ table_name, column_name ])
    SELECT data_type, udt_name, column_default, is_nullable
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = $1
      AND column_name = $2
  SQL

  result.ntuples.zero? ? nil : result[0]
end


def print_column(table_name, column_name, metadata)
  puts "#{table_name}.#{column_name}:"
  unless metadata
    puts "  exists: no"
    return
  end

  puts "  exists: yes"
  puts "  data_type: #{safe_value(metadata.fetch("data_type"))}"
  puts "  udt_name: #{safe_value(metadata.fetch("udt_name"))}"
  puts "  column_default: #{safe_value(metadata["column_default"] || "NULL")}"
  puts "  is_nullable: #{safe_value(metadata.fetch("is_nullable"))}"
end

connection = nil
read_only_transaction_started = false

begin
  database_url = ENV.fetch("DATABASE_URL")
  abort "DATABASE_URL is not configured" if database_url.empty?

  # Do not log database_url or any connection exception text: either may
  # contain credentials, hostnames, or other production configuration.
  connection = PG.connect(database_url)
  connection.exec("BEGIN READ ONLY")
  read_only_transaction_started = true

  questions_relay_column = column_metadata(connection, "questions", "is_relay_question")
  answering_started_column = column_metadata(connection, "quiz_sessions", "answering_started_at")
  confidence_level_column = column_metadata(
    connection,
    "participant_quiz_confidence_selections",
    "confidence_level"
  )

  phase_constraints = connection.exec(<<~SQL)
    SELECT con.conname AS name,
           pg_get_constraintdef(con.oid, true) AS definition
    FROM pg_catalog.pg_constraint AS con
    JOIN pg_catalog.pg_class AS rel ON rel.oid = con.conrelid
    JOIN pg_catalog.pg_namespace AS namespace ON namespace.oid = rel.relnamespace
    WHERE namespace.nspname = 'public'
      AND rel.relname = 'quiz_sessions'
      AND con.contype = 'c'
      AND lower(pg_get_constraintdef(con.oid, true)) LIKE '%phase%'
      AND lower(pg_get_constraintdef(con.oid, true)) LIKE '%closing%'
    ORDER BY con.conname
  SQL

  schema_migrations_present = table_exists?(connection, "schema_migrations")
  migration_version_present = if schema_migrations_present
    result = connection.exec_params(
      "SELECT EXISTS (SELECT 1 FROM public.schema_migrations WHERE version = $1) AS present",
      [ "20260918070000" ]
    )
    result[0]["present"] == "t"
  else
    false
  end

  puts "Production schema audit (read-only)"
  puts "connection: established"
  print_column("public.questions", "is_relay_question", questions_relay_column)
  print_column("public.quiz_sessions", "answering_started_at", answering_started_column)
  confidence_table_present = table_exists?(connection, "participant_quiz_confidence_selections")
  puts "public.participant_quiz_confidence_selections table: #{confidence_table_present ? "present" : "absent"}"
  print_column(
    "public.participant_quiz_confidence_selections",
    "confidence_level",
    confidence_level_column
  )

  puts "public.quiz_sessions check constraints containing phase and closing: #{phase_constraints.ntuples}"
  phase_constraints.each do |constraint|
    puts "  name: #{safe_value(constraint.fetch("name"))}"
    puts "  definition: #{safe_value(constraint.fetch("definition"))}"
  end

  puts "public.schema_migrations version 20260918070000: #{migration_version_present ? "present" : "absent"}"
  puts "audit completed: read-only transaction rolled back"
rescue KeyError
  warn "production schema audit failed: configuration is missing"
  exit 20
rescue StandardError => error
  # Never print error.message because adapter errors can include the complete
  # DATABASE_URL. The class name is stable and contains no connection data.
  warn "production schema audit failed: #{error.class.name}"
  exit 20
ensure
  if connection
    begin
      connection.exec("ROLLBACK") if read_only_transaction_started
    rescue StandardError
      # The connection is closed immediately below; do not expose adapter data.
    end
    connection.close
  end
end
