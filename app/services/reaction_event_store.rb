# Ephemeral, process-local feed for projector reactions. It deliberately contains
# no participant attributes and is cleared when the process restarts.
class ReactionEventStore
  REACTIONS = %w[👏 🎉 🙌 😂 😢 😲 👍 ❤️].freeze
  MAX_EVENTS = 100
  RETENTION = 30.seconds
  REACTION_COOLDOWN = 0.5.seconds

  Event = Data.define(:id, :reaction, :at)

  class InvalidReaction < StandardError; end

  class << self
    def record(session_id:, reaction:, at: Time.current)
      raise InvalidReaction unless REACTIONS.include?(reaction)

      # The API cursor is serialized to microseconds, so retain the same
      # precision internally. Otherwise a nanosecond remainder makes the last
      # event compare greater than its own returned cursor and replay once.
      at = at.floor(6)

      mutex.synchronize do
        prune!(at)
        return nil if rate_limited?(session_id, at)

        last_reaction_at_by_session[session_id] = at
        events << Event.new(id: SecureRandom.uuid, reaction:, at:)
        events.shift while events.length > MAX_EVENTS
        events.last
      end
    end

    def events_since(since:, now: Time.current)
      mutex.synchronize do
        prune!(now)
        events.select { |event| event.at > since }
      end
    end

    # Used by a completed tournament reset and test setup. The store has no
    # durable state, so clearing it does not participate in the DB transaction.
    def clear!
      mutex.synchronize do
        events.clear
        last_reaction_at_by_session.clear
      end
    end

    private

    def mutex
      @mutex ||= Mutex.new
    end

    def events
      @events ||= []
    end

    def last_reaction_at_by_session
      @last_reaction_at_by_session ||= {}
    end

    def rate_limited?(session_id, at)
      last_at = last_reaction_at_by_session[session_id]
      last_at && last_at >= at - REACTION_COOLDOWN
    end

    def prune!(now)
      cutoff = now - RETENTION
      events.reject! { |event| event.at <= cutoff }
      last_reaction_at_by_session.delete_if { |_session_id, at| at <= cutoff }
    end
  end
end
