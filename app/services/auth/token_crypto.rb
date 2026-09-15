require "digest"
require "securerandom"

# Shared cryptographic primitives for device-bound cookie sessions.
# Raw tokens are never persisted; only their SHA-256 digests are stored.
module Auth
  module TokenCrypto
    def token
      SecureRandom.urlsafe_base64(32, false)
    end

    def digest(value)
      Digest::SHA256.digest(value)
    end

    def valid_token?(value)
      value.is_a?(String) && value.match?(/\A[A-Za-z0-9_-]{40,64}\z/)
    end

    def secure_equal?(left, right)
      left.is_a?(String) && right.is_a?(String) && left.bytesize == right.bytesize && ActiveSupport::SecurityUtils.secure_compare(left, right)
    end
  end
end
