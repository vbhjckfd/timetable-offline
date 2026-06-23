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
