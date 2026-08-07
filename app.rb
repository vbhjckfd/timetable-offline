require 'sinatra/base'
require 'faraday'
require 'rqrcode'
require 'base64'
require 'erb'
require "active_support/all"

require_relative './eng_names.rb'

ENG_NAMES_BY_CODE = ENG_NAMES.each_with_object({}) { |entry, h| h[entry[:code]] = entry[:eng_name] }.freeze

# The API is the source of truth for English names: it covers more stops than
# eng_names.rb and is kept current (e.g. stop 27 is "Lem Square" upstream, still
# "Sakharova" in the table). The table is only a fallback for stops the API has
# no translation for, and stops in neither get an empty string rather than a 500.
def eng_name_for(code, api_name)
  return api_name if api_name.present?

  ENG_NAMES_BY_CODE[code.to_i] || ''
end

def detect_layout(transfers)
  routeTypesCount = transfers.keys.length
  routesCount = transfers.values.flatten.length

  if (routeTypesCount == 1 && routesCount <= 3)
    n = 3
  elsif ([1, 2].include?(routeTypesCount) && routesCount <= 8 && transfers.values.all? {|rs| rs.length <= 4 })
    n = 8
  else
    n = 28
  end
  n
end

VEHICLE_TYPES = {
  'bus' => :bus,
  'tram' => :tram,
  'trol' => :trol,
  'trolleybus' => :trol,
}.freeze

# Cyrillic route names map onto Latin icon filenames: А03 → a03 → a3 → 3 → 3a,
# Т25 → t25, Аеропорт → airport.
def normalize_route_name(route)
  name = route.to_s.downcase
  name = name.gsub(/[тан]/, 'т' => 't', 'а' => 'a', 'н' => 'n')
  name = name.gsub('a0', 'a')
  name = name.gsub('t0', 't')
  name = name.gsub('n0', 'n')
  name = name[1..-1] if name.chr == "a"
  name = 'airport' if name == "еропорt"
  name = name + "a" if ["1", "2", "3", "4", "5", "6", "36", "47"].include? name
  name
end

def get_transfers(data)
  transfers = {
    bus: [],
    tram: [],
    trol: [],
    night: [],
  }

  Array(data['transfers']).each do |t|
    name = normalize_route_name(t['route'])

    # Night routes are Н-prefixed whatever vehicle the API says runs them, and
    # the normalised name is where that prefix has become a Latin n.
    if name.start_with? 'n'
      type = :night
    else
      type = VEHICLE_TYPES.fetch(t['vehicle_type'], :bus)
    end

    t['route_normalized'] = name

    t['eng_end_stop_name'] = eng_name_for(t['end_stop_code'], t['end_stop_eng_name'])

    transfers[type] << t
  end

  transfers = transfers.delete_if { |k, v| v.empty? }
end

# The normalised name is also the icon filename, interpolated straight into an
# xlink:href, so anything that is not a plain badge name never gets that far.
ROUTE_TOKEN = /\A[a-z0-9]{1,8}\z/

# The API has no vehicle type for a route it does not know serves the stop, so
# it is read off the prefix: Т/T trolleybus, А/A bus, Н/N night, bare digits tram.
def infer_vehicle_type(route)
  case route.to_s.downcase.gsub(/[тан]/, 'т' => 't', 'а' => 'a', 'н' => 'n').chr
  when 't' then 'trol'
  when 'a', 'n' then 'bus'
  else 'tram'
  end
end

# ?add=A46,T02&remove=T03,A47 — hand-editing of the route list, for stops whose
# upstream data is behind reality. Both sides match on the normalised name, so
# "A47", Cyrillic "А47" and "47" all mean the same route. Added routes carry no
# destination: the API only names end stops for routes it says serve the stop.
def apply_route_overrides(data, add: nil, remove: nil)
  transfers = Array(data['transfers'])

  removed = add_remove_tokens(remove).map { |token| normalize_route_name(token) }
  transfers = transfers.reject { |t| removed.include?(normalize_route_name(t['route'])) }

  present = transfers.map { |t| normalize_route_name(t['route']) }

  add_remove_tokens(add).each do |token|
    name = normalize_route_name(token)
    next unless name.match?(ROUTE_TOKEN)
    next if present.include?(name)

    present << name
    transfers << {
      'route' => token,
      'vehicle_type' => infer_vehicle_type(token),
      'end_stop_code' => nil,
      'end_stop_name' => '',
      'end_stop_eng_name' => '',
    }
  end

  data.merge('transfers' => transfers)
end

def add_remove_tokens(value)
  value.to_s.split(',').map(&:strip).reject(&:empty?)
end

class App < Sinatra::Base
  # Cloud Run gives the whole request 15s, and rendering the schema SVG is not
  # free, so the upstream call has to give up well before that.
  API_OPEN_TIMEOUT = 3
  API_READ_TIMEOUT = 8

  configure do
    set :server, :puma
    set :bind, '0.0.0.0'
  end

  before do
    headers 'X-Robots-Tag' => 'noindex, nofollow'
  end

  helpers do
    def load_stop(stop_code)
      api_url = ENV['API_URL'] || 'https://api.lad.lviv.ua'
      # url_encode, not raw interpolation: Sinatra decodes %2F after matching
      # :code, so an unescaped code can climb out of the /stops/ path.
      url = "#{api_url}/stops/#{ERB::Util.url_encode(stop_code)}/static"

      begin
        response = Faraday.get(url) do |req|
          req.options.open_timeout = API_OPEN_TIMEOUT
          req.options.timeout = API_READ_TIMEOUT
        end
      rescue Faraday::Error => e
        warn "upstream request failed for stop #{stop_code}: #{e.class}: #{e.message}"
        halt 503, 'Сервіс тимчасово недоступний'
      end

      halt 400, 'Код зупинки має бути числом, на кшталт 128' if response.status == 400
      halt 404, 'Неправильний код зупинки' if response.status == 404
      halt 503, 'Сервіс тимчасово недоступний' unless response.success?

      begin
        JSON.parse(response.body)
      rescue JSON::ParserError
        halt 503
      end
    end
  end

  # "schema" is the poster the old drawing left behind, with the new map and
  # legend dropped into it; "schema-1" is the new drawing taken whole, with only
  # the per-stop layer on top. Both read the same data.
  ['/:code/schema', '/:code/schema-1'].each do |route|
    template = route.end_with?('-1') ? :scheme_1 : :scheme

    get route do
      stop_code = params['code']

      data = load_stop(stop_code)
      data = apply_route_overrides(data, add: params['add'], remove: params['remove'])
      transfers = get_transfers(data)

      data['name_en'] = eng_name_for(stop_code, data['eng_name'])

      erb template,
      :locals => {
        data: data,
        transfers: transfers
      },
      content_type: 'image/svg+xml'
    end
  end

  # get '/:code.pdf' do
  #   require 'pdfkit'


  #   stop_code = params['code']

  #   kit = PDFKit.new("http://localhost:4567/#{stop_code}", {
  #       'page-height' => '350mm',
  #       'page-width'=> '500mm',
  #       'margin-top' => 0,
  #       'margin-right' => 0,
  #       'margin-bottom' => 0,
  #       'margin-left' => 0,
  #       'zoom' => 0.5,
  #   })

  #   pdf = kit.to_pdf
  #   if (params[:download])
  #     return 'Not implemented'
  #     io = StringIO.new(pdf)
  #     send_file(io, :disposition => 'attachment', :filename => "#{stop_code}.pdf")
  #   end

  #   content_type 'application/pdf'
  #   pdf
  # end

  get '/:code' do
    stop_code = params['code']

    data = load_stop(stop_code)
    data = apply_route_overrides(data, add: params['add'], remove: params['remove'])
    transfers = get_transfers(data)

    n = detect_layout(transfers)

    qrcode = RQRCode::QRCode.new("https://lad.lviv.ua/#{stop_code}")
    svg = qrcode.as_svg(
      offset: 0,
      color: '000',
      shape_rendering: 'crispEdges',
      module_size: 6,
      standalone: true
    ).to_s.sub('<?xml version="1.0" standalone="yes"?>', '')

    [
      'Винники, ',
      'Винники. ',
      'Дубляни, ',
      'Брюховичі, ',
      'Брюховичі. ',
      'Великий Дорошів, ',
      'Підрясне, ',
      'Рясне-Руське, ',
      'Воля Гамулецька, ',
      'Гряда, ',
      'Завадів, ',
      'Зашків, ',
      'Малехів, ',
      'Лисиничі, ',
      'Підбірці, ',
      'Великі Грибовичі, ',
      'Малі грибовичі, ',
      'Малі Грибовичі, ',
      'Муроване, ',
      'Рудно, ',
      'Рудне, ',
    ].each {|s| data['name'] = data['name'].to_s.sub(s, '') }
    data['name'] = data['name'].to_s.upcase_first

    erb "layout-#{n}".to_sym,
    :locals => {
      data: data,
      transfers: transfers,
      qrcode: svg,
    },
    content_type: 'image/svg+xml'
  end

end

App.run! if __FILE__ == $0
