# Must be set before Sinatra is loaded. Sinatra 4's Rack::Protection::HostAuthorization
# only permits localhost-ish hosts in the development environment, which would 403 every
# rack-test request (they come from "example.org").
ENV['APP_ENV'] ||= 'test'

require 'rack/test'
require 'webmock/rspec'
require_relative '../app'

API_BASE = (ENV['API_URL'] || 'https://api.lad.lviv.ua').freeze

RSpec.configure do |config|
  config.include Rack::Test::Methods

  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end
end

# How a rendered drawing embeds public/icons/<name>.svg.
def icon(name)
  "data:image/svg+xml;base64,#{Base64.strict_encode64(File.binread(File.join(__dir__, '..', 'public', 'icons', "#{name}.svg")))}"
end
