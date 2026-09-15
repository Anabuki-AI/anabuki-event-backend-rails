# Shared HttpOnly cookie helpers for device-bound sessions.
#
# Including classes are expected to expose an action-dispatch cookie jar as
# @cookies and a config responding to #secure_cookies? (see Auth::Config).
module Auth
  module CookieSession
    def ensure_device_cookie!(cookie_name, ttl)
      device = @cookies[cookie_name]
      return device if valid_token?(device)

      device = token
      write_cookie(cookie_name, device, ttl)
      device
    end

    def write_cookie(name, value, ttl)
      @cookies[name] = cookie_options.merge(value:, expires: ttl.from_now)
    end

    def cookie_options
      { httponly: true, same_site: :lax, secure: @config.secure_cookies?, path: "/" }
    end
  end
end
