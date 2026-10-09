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

# A route the API does not list for the stop, built from its name alone. There
# is no destination to give it: the API only names end stops for routes it says
# serve the stop. nil for a name that is not a plain badge.
def synthesized_route(token)
  return nil unless normalize_route_name(token).match?(ROUTE_TOKEN)

  {
    'route' => token,
    'vehicle_type' => infer_vehicle_type(token),
    'end_stop_code' => nil,
    'end_stop_name' => '',
    'end_stop_eng_name' => '',
  }
end

# ?only=A46,T02&add=…&remove=… — hand-editing of the route list, for stops whose
# upstream data is behind reality. Applied in that order: only replaces the list
# outright, remove drops routes, add appends them. Every side matches on the
# normalised name, so "A47", Cyrillic "А47" and "47" all mean the same route.
#
# only is the whole list, in the order written: a name the API does list keeps
# its upstream data, a name it does not is built from the name alone.
def apply_route_overrides(data, only: nil, add: nil, remove: nil)
  transfers = Array(data['transfers'])

  kept = route_tokens(only).uniq { |token| normalize_route_name(token) }
  if kept.any?
    upstream = transfers.group_by { |t| normalize_route_name(t['route']) }
    transfers = kept.flat_map do |token|
      upstream[normalize_route_name(token)] || synthesized_route(token)
    end.compact
  end

  removed = route_tokens(remove).map { |token| normalize_route_name(token) }
  transfers = transfers.reject { |t| removed.include?(normalize_route_name(t['route'])) }

  present = transfers.map { |t| normalize_route_name(t['route']) }

  route_tokens(add).each do |token|
    name = normalize_route_name(token)
    next if present.include?(name)

    entry = synthesized_route(token)
    next if entry.nil?

    present << name
    transfers << entry
  end

  data.merge('transfers' => transfers)
end

# Where each stop name sits on the network drawing, poster coordinates, with the tram
# and trolleybus numbers whose lines run through each spot; built by
# tools/extract_map_labels.py. Names are matched the way that script keys them.
MAP_LABELS = JSON.parse(File.read(File.join(__dir__, 'data', 'map_labels.json'))).freeze
# Stop code -> {at: spots, walk: nil | the pinned stop it points at}, for stops the name
# cannot place: Бандери (one marker per direction), tram/trolleybus stops the drawing does
# not label, and stops off the drawing within a short walk of one on it.
MAP_STOP_PINS = JSON.parse(File.read(File.join(__dir__, 'data', 'map_stop_pins.json'))).freeze

ELECTRIC_TYPES = %w[tram trolleybus trol].freeze

# The drawing's tram (1-9) and trolleybus (22-38) lines, keyed by the colour each is drawn
# in, as tools/extract_map_labels.py reads them. A line's stroke and its end badge's fill
# differ by a shade, so every colour the route groups use is matched to the nearest here.
ROUTE_COLOURS = {
  '#e41e0e' => 1, '#915134' => 2, '#4baf50' => 3, '#009bd6' => 4, '#933d90' => 6, '#0c67b1' => 7, '#929292' => 8,
  '#0f5c1c' => 9, '#359a7a' => 22, '#ba7f5e' => 23, '#e8e348' => 24, '#e94d09' => 25, '#afca06' => 27,
  '#25328a' => 29, '#f086a9' => 30, '#078e2e' => 31, '#e50063' => 32, '#6f7e28' => 33, '#9c0b01' => 38,
}.freeze
# The drawing's groups that hold route lines and their end badges.
ROUTE_GROUPS = %w[scheme-tmp-29 scheme-routes scheme-tmp-30 scheme-anna scheme-numbers-bold].freeze

def route_of_colour(hex)
  rgb = ->(h) { [h[1, 2], h[3, 2], h[5, 2]].map { |c| c.to_i(16) } }
  off = ->(c) { rgb.(c).zip(rgb.(hex)).sum { |a, b| (a - b)**2 } }
  best = ROUTE_COLOURS.keys.min_by(&off)
  ROUTE_COLOURS[best] if off.(best) < 300
end

# Every colour drawn in the route groups -> the route it belongs to.
ROUTE_INK = begin
  svg = File.read(File.join(__dir__, 'views', 'scheme.erb'), encoding: 'utf-8')
  ROUTE_GROUPS.flat_map do |group|
    body = svg[/<g id="#{group}">\n(.*?)\n<\/g>/m, 1].to_s
    body.scan(/(?:stroke|fill)="(#\h{6})"/).flatten
  end.uniq.to_h { |hex| [hex, route_of_colour(hex)] }.compact.freeze
end

# The colours of the drawing's lines that do not serve this stop, to fade so its own stand
# out; none for a stop with no tram or trolleybus line on the drawing (buses are not drawn).
def faded_route_colours(transfers)
  ours = Array(transfers).select { |t| ELECTRIC_TYPES.include?(t['vehicle_type']) }
                         .map { |t| t['route'].to_s.gsub(/\D/, '').to_i }
  return [] if (ROUTE_INK.values & ours).empty?

  ROUTE_INK.reject { |_, route| ours.include?(route) }.keys.sort
end

# CSS fading those colours. An end badge is its fill followed by the path of each digit,
# white or (on the light badges) black, so the digits go with it.
def faded_routes_css(transfers)
  faded = faded_route_colours(transfers)
  return nil if faded.empty?

  selectors = faded.flat_map do |c|
    lines = ROUTE_GROUPS.map { |g| %(##{g} [stroke="#{c}"], ##{g} [fill="#{c}"]) }
    digits = %w[#ffffff #1a1a18].flat_map do |d|
      badge = %(#scheme-numbers-bold [fill="#{c}"])
      [%(#{badge} + [fill="#{d}"]), %(#{badge} + [fill="#{d}"] + [fill="#{d}"])]
    end
    lines + digits
  end
  "#{selectors.join(",\n")} { opacity: 0.2 }"
end

# Some names sit on the drawing twice, once per line (Залізняка: trolleybuses 22/30 and
# tram 2 stop apart), so keep the spots on this stop's own lines. A stop on none of
# them (buses only, or a line the drawing does not pin there) keeps them all.
def map_pins_for(name, transfers)
  pins = MAP_LABELS.fetch(name.to_s.downcase.gsub(/[^[:alnum:]]/, ''), [])
  lines = Array(transfers).select { |t| ELECTRIC_TYPES.include?(t['vehicle_type']) }
                          .map { |t| t['route'].to_s.gsub(/\D/, '').to_i }
  ours = pins.select { |_, _, served| (Array(served) & lines).any? }
  (ours.empty? ? pins : ours).map { |x, y, _| [x, y] }
end

# What to draw for a stop: the spots to pin, and for a stop the drawing does not carry, the
# nearby stop those spots belong to (name, English name, metres away as the crow flies).
def map_spot_for(code, name, transfers)
  entry = MAP_STOP_PINS[code.to_s]
  return { pins: map_pins_for(name, transfers), walk: nil } unless entry

  walk = entry['walk'] && entry['walk'].merge('name_en' => eng_name_for(entry['walk']['code'], entry['walk']['name_en']))
  { pins: entry['at'], walk: walk }
end

# The schema's route-direction column, top right: one section per vehicle type, stacked
# tram, trolleybus, bus, each a header and one row per route. Coordinates are the
# column's own (before its translate(-642.2, -270)). The drawing's legend starts below
# DIRECTIONS_BOTTOM, so a column that would run into it is scaled down to fit.
DIRECTIONS_TOP = 813.0
DIRECTIONS_BOTTOM = 3500.0
DIRECTIONS_ROW = 119.87
# Header baseline to the next section's header, less one row per route above it.
DIRECTIONS_SECTION_GAP = 325.41
# Header baseline to the bottom of the last row's English line, less one row per route.
DIRECTIONS_SECTION_TAIL = 78.73

def directions_layout(transfers)
  y = 873.0
  sections = %i[tram trol bus].filter_map do |type|
    rows = Array(transfers[type]).length
    next if rows.zero?

    section = { type: type, header_y: y, bottom: y + DIRECTIONS_SECTION_TAIL + DIRECTIONS_ROW * rows }
    y += DIRECTIONS_SECTION_GAP + DIRECTIONS_ROW * rows
    section
  end

  bottom = sections.empty? ? DIRECTIONS_TOP : sections.last[:bottom]
  scale = [1.0, (DIRECTIONS_BOTTOM - DIRECTIONS_TOP) / (bottom - DIRECTIONS_TOP)].min
  { sections: sections.to_h { |s| [s[:type], s[:header_y]] }, scale: scale }
end

def route_tokens(value)
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
    # Cloudflare bypasses these today, but only because of a rule that lives
    # outside this repo; the query params make a stale sticker easy to hit, so
    # say it here rather than rely on that.
    cache_control :no_store
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
      halt 404, erb(:not_found, layout: false, content_type: 'text/html') if response.status == 404
      halt 503, 'Сервіс тимчасово недоступний' unless response.success?

      begin
        JSON.parse(response.body)
      rescue JSON::ParserError
        halt 503
      end
    end
  end

  # The 2026 network drawing taken whole, with only the per-stop layer on top.
  get '/:code/schema' do
    stop_code = params['code']

    data = load_stop(stop_code)
    data = apply_route_overrides(data, only: params['only'], add: params['add'], remove: params['remove'])
    transfers = get_transfers(data)

    data['name_en'] = eng_name_for(stop_code, data['eng_name'])

    erb :scheme,
    :locals => {
      data: data,
      transfers: transfers,
      spot: map_spot_for(stop_code, data['name'], data['transfers'])
    },
    content_type: 'image/svg+xml'
  end

  # schema-1 was where the 2026 poster lived while the old one still held /schema.
  get '/:code/schema-1' do
    query = request.query_string.empty? ? '' : "?#{request.query_string}"
    redirect "/#{ERB::Util.url_encode(params['code'])}/schema#{query}", 301
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
    data = apply_route_overrides(data, only: params['only'], add: params['add'], remove: params['remove'])
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
