# The Nuxt development proxy normally makes this unnecessary. This is a narrow
# fallback for direct browser calls; origins come only from explicit public URLs.
Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins do |origin, _env|
      [ ENV.fetch("PUBLIC_BASE_URL", "http://localhost:3000"), ENV.fetch("ADMIN_FRONTEND_URL", "http://localhost:3000/admin") ]
        .map { |url| URI.parse(url).then { |uri| "#{uri.scheme}://#{uri.host}#{uri.port && ![ 80, 443 ].include?(uri.port) ? ":#{uri.port}" : ""}" } }
        .include?(origin)
    rescue URI::InvalidURIError
      false
    end
    resource "*", headers: :any, methods: %i[get post delete options], credentials: true
  end
end
