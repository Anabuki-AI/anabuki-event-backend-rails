require "json"
require "net/http"
require "uri"

# Small, injectable HTTP boundary for monitoring providers. It never logs
# request headers, which may contain provider credentials.
class AdminApiStatusTransport
  Response = Data.define(:status, :body)

  class Error < StandardError; end

  def request(method:, url:, headers: {}, json: nil)
    uri = URI.parse(url)
    raise Error, "Monitoring endpoint must use HTTPS" unless uri.is_a?(URI::HTTPS) && uri.host.present?

    request = build_request(method, uri, headers, json)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 3
    http.read_timeout = 5
    http.write_timeout = 5

    response = http.request(request)
    Response.new(response.code.to_i, response.body.to_s)
  rescue URI::InvalidURIError, SocketError, Timeout::Error, Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, IOError, SystemCallError => error
    raise Error, error.class.name
  end

  private

  def build_request(method, uri, headers, json)
    request_class = method.to_s.upcase == "POST" ? Net::HTTP::Post : Net::HTTP::Get
    request = request_class.new(uri.request_uri)
    headers.each { |name, value| request[name] = value }
    if json
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(json)
    end
    request
  end
end
