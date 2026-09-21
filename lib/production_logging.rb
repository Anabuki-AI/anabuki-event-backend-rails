require "active_support"
require "active_support/logger"
require "active_support/tagged_logging"
require "active_support/broadcast_logger"
require "active_support/parameter_filter"
require "json"

module ProductionLogging
  def self.build(env: ENV, stdout: STDOUT)
    logger = ActiveSupport::TaggedLogging.logger(stdout)
    path = env["RAILS_LOG_PATH"]
    if path && !path.strip.empty?
      count = positive_integer(env, "RAILS_LOG_ROTATION_COUNT", 10)
      size = positive_integer(env, "RAILS_LOG_ROTATION_SIZE", 20 * 1024 * 1024)
      # Keep this process-wide mask for files created during later rotations too.
      File.umask(File.umask | 0o027)
      File.open(path, File::WRONLY | File::APPEND | File::CREAT, 0o640) do |file|
        file.chmod(file.stat.mode & 0o640)
      end
      file_logger = ActiveSupport::Logger.new(path, count, size)
      # Tag the broadcaster itself so a tagged block executes only once.
      logger = ActiveSupport::TaggedLogging.new(ActiveSupport::BroadcastLogger.new(logger, file_logger))
    end
    # Rails 8.1 treats a BroadcastLogger's initially nil broadcast_level specially.
    logger.level = env.fetch("RAILS_LOG_LEVEL", "info")
    logger
  end

  def self.positive_integer(env, key, default)
    value = Integer(env.fetch(key, default).to_s, 10)
    raise ArgumentError, "#{key} must be a positive integer" unless value.positive?
    value
  rescue ArgumentError
    raise ArgumentError, "#{key} must be a positive integer"
  end

  def self.que_formatter(filters)
    filter = ActiveSupport::ParameterFilter.new(filters)
    # Que 2.4 normally JSON.dumps its event hash, including job args/kwargs.
    ->(data) { JSON.dump(filter.filter(redact_arguments(data))) }
  end

  def self.redact_arguments(value)
    case value
    when Hash
      value.each_with_object({}) do |(key, item), result|
        result[key] = if %w[args kwargs].include?(key.to_s)
          case item
          when Array then item.map { "[FILTERED]" }
          when Hash then item.transform_values { "[FILTERED]" }
          else "[FILTERED]"
          end
        else
          redact_arguments(item)
        end
      end
    when Array then value.map { |item| redact_arguments(item) }
    else value
    end
  end
end
