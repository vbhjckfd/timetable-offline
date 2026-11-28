require 'sinatra/base'
require 'faraday'
require 'rqrcode'
require 'base64'
require 'erb'
require 'cgi'

require_relative './eng_names.rb'

ENG_NAMES_BY_CODE = ENG_NAMES.each_with_object({}) { |entry, h| h[entry[:code]] = entry[:eng_name] }.freeze

# NatGrotesk comes only as an SVG font, cut from the city's panel template. The
# panel embeds the OpenType font tools/natgrotesk_otf.py builds from it, which
# browsers render too, and measures names with the SVG font's glyph advances
# (per 1000 units of em) to centre and shrink them.
NATGROTESK_OTF = Base64.strict_encode64(File.binread(File.join(__dir__, 'public/fonts/NatGrotesk/NatGrotesk-Regular.otf'))).freeze
NATGROTESK_SVG = File.read(File.join(__dir__, 'public/fonts/NatGrotesk/NatGrotesk-Regular.svg'))
NATGROTESK_DEFAULT_ADVANCE = NATGROTESK_SVG[/<font\b[^>]*\shoriz-adv-x="([\d.]+)"/, 1].to_f
NATGROTESK_ADVANCES = NATGROTESK_SVG.scan(/<glyph unicode="([^"]*)" horiz-adv-x="([\d.]+)"/)
                                    .to_h { |glyph, advance| [CGI.unescapeHTML(glyph), advance.to_f] }.freeze

def natgrotesk_width(text, size)
  text.to_s.each_char.sum { |c| NATGROTESK_ADVANCES.fetch(c, NATGROTESK_DEFAULT_ADVANCE) } * size / 1000.0
end

# The API is the source of truth for English names: it covers more stops than
# eng_names.rb and is kept current (e.g. stop 27 is "Lem Square" upstream, still
# "Sakharova" in the table). The table is only a fallback for stops the API has
# no translation for, and stops in neither get an empty string rather than a 500.
def eng_name_for(code, api_name)
  name = api_name.to_s.strip.empty? ? (ENG_NAMES_BY_CODE[code.to_i] || '') : api_name
  # English labels spell numbers "#5", not the Cyrillic-style "№ 5" the API sends.
  name.gsub(/\s*№\s*/, ' #').strip
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

ICON_HREFS = Dir[File.join(__dir__, 'public', 'icons', '*.svg')].to_h do |path|
  [File.basename(path, '.svg'), "data:image/svg+xml;base64,#{Base64.strict_encode64(File.binread(path))}"]
end.freeze

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

# The API has no running times between stops, so each stop's minutes from the one the sheet
# is for come from the straight-line distance along the route.
# shortcut: 215 m/min is fitted to the city's Т03 sheet and ignores road curvature and
# dwell time, swap in real running times if the API ever carries them.
METRES_PER_MINUTE = 215.0

def metres_between(a, b)
  rad = Math::PI / 180
  dlat = (b[0] - a[0]) * rad
  dlon = (b[1] - a[1]) * rad
  h = Math.sin(dlat / 2)**2 + Math.cos(a[0] * rad) * Math.cos(b[0] * rad) * Math.sin(dlon / 2)**2
  12_742_000 * Math.asin(Math.sqrt(h))
end

# A stop sheet for one route: the stops from this one to the end of the line with minutes
# to each, and the departures from here by hour, per day column (see below). nil when
# the route does not leave from this stop, as the API carries departures only for a line's
# terminal stops.
def schedule_for(stop_code, transfer, route)
  stops = Array(route['stops'][transfer['direction_id'].to_i])
  at = stops.index { |s| s['code'].to_i == stop_code.to_i }
  return nil if at.nil?

  # The API's weekend is Saturday and Sunday merged, so a route whose two days differ gets
  # a column for each; otherwise one weekend column.
  schedule = stops[at]['schedule'] || {}
  saturday = schedule['saturday'] || schedule['weekend']
  sunday = schedule['sunday'] || schedule['weekend']
  days = { 'workday' => schedule['workday'] }
  days.merge!(saturday == sunday ? { 'weekend' => saturday } : { 'saturday' => saturday, 'sunday' => sunday })

  departures = days.transform_values do |times|
    Array(times).group_by { |t| t[0, 2].to_i }.transform_values { |ts| ts.map { |t| t[3, 2].to_i }.sort }
  end
  return nil if departures.values.all?(&:empty?)

  walked = 0.0
  next_stops = stops[at..].each_cons(2).map do |from, to|
    walked += metres_between(from['loc'], to['loc'])
    { 'name' => to['name'], 'code' => to['code'], 'minutes' => [1, (walked / METRES_PER_MINUTE).round].max,
      'loc' => to['loc'], 'transfers' => Array(to['transfers']) }
  end

  here = { 'code' => stops[at]['code'], 'loc' => stops[at]['loc'], 'transfers' => Array(stops[at]['transfers']) }
  { departures: departures, next_stops: elide_middle(next_stops), here: here }
end

# The sheet's stop list stays readable up to MAX_NEXT_STOPS rows; a longer line keeps its
# first and last stops and gives up the middle to a gap row. A line that starts and ends in
# quiet suburbs instead keeps a few stops at each end and the window between them holding the
# most interchanges, with a gap row on either side. Gap rows carry the routes running on both
# sides of them so their lanes go on across.
MAX_NEXT_STOPS = 15
EDGE_STOPS = 3

def elide_middle(stops)
  return stops if stops.length <= MAX_NEXT_STOPS

  interchanges = ->(range) { stops[range].sum { |s| s['transfers'].length } }
  keep = (MAX_NEXT_STOPS - 1) / 2
  single = [0...keep, (stops.length - (MAX_NEXT_STOPS - 1 - keep))...stops.length]

  window = MAX_NEXT_STOPS - 2 * EDGE_STOPS - 2
  middle = ((EDGE_STOPS + 1)..(stops.length - EDGE_STOPS - window - 1)).map { |at| at...(at + window) }
                                                                       .max_by { |r| [interchanges.(r), -r.begin] }
  double = [0...EDGE_STOPS, middle, (stops.length - EDGE_STOPS)...stops.length]

  pieces = double.sum(&interchanges) > single.sum(&interchanges) ? double : single
  pieces.map { |r| stops[r] }.reduce { |rows, piece| [*rows, gap_row(rows.last, piece.first), *piece] }
end

def gap_row(before, after)
  routes = after['transfers'].map { |t| t['route'] }
  { 'gap' => true, 'transfers' => before['transfers'].select { |t| routes.include?(t['route']) } }
end

ELECTRIC = %i[tram trol].freeze

def vehicle_type_of(transfer)
  VEHICLE_TYPES.fetch(transfer['vehicle_type'], :bus)
end

# The sheet's stop list draws other routes as lanes beside its line, over the rows (0 is
# the stop the sheet is for) where both stop, split into unbroken runs: the sheet route's
# own kind for a tram or trolleybus, both of those for a bus. Never buses. Beside a bus a
# lane must run on for two stops or more: one that only crosses it is an interchange. The
# lane that stays longest sits next to the line, so the shorter ones peel off outside.
def parallel_lanes(route, rows)
  type = vehicle_type_of(route)
  kinds = ELECTRIC.include?(type) ? [type] : ELECTRIC

  at = Hash.new { |h, k| h[k] = { route: nil, rows: [] } }
  rows.each_with_index do |transfers, i|
    Array(transfers).each do |t|
      next if !kinds.include?(vehicle_type_of(t)) || t['route'] == route['route']

      at[t['route']][:route] ||= t
      at[t['route']][:rows] << i
    end
  end

  lanes = at.values.map do |lane|
    runs = lane[:rows].uniq.slice_when { |a, b| b != a + 1 }.map { |run| [run.first, run.last] }
    runs.reject! { |a, b| a == b } if kinds == ELECTRIC
    { route: lane[:route], runs: runs } unless runs.empty?
  end.compact
  lanes.sort_by { |lane| [-lane[:runs].last.last, lane[:runs].first.first, lane[:route]['route'].to_s] }
end

# The interchanges written to the left of a stop: trams and trolleybuses of a kind other
# than the sheet route's, grouped by kind, less those drawn as lanes there. Never buses.
def other_electric(route, transfers, laned = [])
  type = vehicle_type_of(route)
  Array(transfers).select { |t| ELECTRIC.include?(vehicle_type_of(t)) && vehicle_type_of(t) != type }
                  .reject { |t| laned.include?(t['route']) }
                  .uniq { |t| t['route'] }
                  .sort_by { |t| [ELECTRIC.index(vehicle_type_of(t)), t['route'].to_s] }
                  .group_by { |t| vehicle_type_of(t) }
end

class App < Sinatra::Base
  # Cloud Run gives the whole request 15s, and rendering the schema SVG is not
  # free, so the upstream call has to give up well before that.
  API_OPEN_TIMEOUT = 3
  API_READ_TIMEOUT = 8
  # Nearby interchanges on a schedule sheet: within a short walk, looked up for every stop
  # at once, and given up on as a whole after NEARBY_DEADLINE seconds.
  NEARBY_METRES = 200
  NEARBY_TIMEOUT = 2
  NEARBY_DEADLINE = 4

  # The schema SVG is 8-16 MB raw, ~2.5 MB gzipped; Cloud Run bills egress on
  # the bytes leaving the origin, before Cloudflare's own compression.
  use Rack::Deflater

  configure do
    set :server, :puma
    set :bind, '0.0.0.0'
  end

  before do
    headers 'X-Robots-Tag' => 'noindex, nofollow'
    # Errors stay uncached; a rendered drawing opts in with cache_at_edge.
    cache_control :no_store
  end

  helpers do
    # Cloudflare keys on the full URL, so each ?only/add/remove/fade variant is
    # its own entry. The daily data refresh purges the `short` tag zone-wide,
    # so a drawing never outlives the stop data it was drawn from; `svg` purges
    # just the drawings.
    def cache_at_edge
      headers 'Cache-Control' => 'public, max-age=0, s-maxage=86400, stale-while-revalidate=86400',
              'Cache-Tag' => 'short,svg'
    end

    # Inlined, not linked: an SVG shown through <img> or saved to disk loads
    # nothing external, so a linked icon would vanish. Unknown names keep the link.
    def icon_href(name)
      ICON_HREFS.fetch(name.to_s) { "/icons/#{ERB::Util.url_encode(name)}.svg" }
    end

    def qr_svg(stop_code)
      RQRCode::QRCode.new("https://lad.lviv.ua/#{stop_code}").as_svg(
        offset: 0,
        color: '000',
        shape_rendering: 'crispEdges',
        module_size: 6,
        standalone: true
      ).to_s.sub('<?xml version="1.0" standalone="yes"?>', '')
    end

    # path is built by the caller from url_encode'd parts: Sinatra decodes %2F after
    # matching :code, so an unescaped one can climb out of the path.
    def api_get(path)
      Faraday.get("#{ENV['API_URL'] || 'https://api.lad.lviv.ua'}#{path}") do |req|
        req.options.open_timeout = API_OPEN_TIMEOUT
        req.options.timeout = API_READ_TIMEOUT
      end
    rescue Faraday::Error => e
      warn "upstream request failed for #{path}: #{e.class}: #{e.message}"
      halt 503, 'Сервіс тимчасово недоступний'
    end

    def parse_api_json(response)
      JSON.parse(response.body)
    rescue JSON::ParserError
      halt 503
    end

    def load_stop(stop_code)
      response = api_get("/stops/#{ERB::Util.url_encode(stop_code)}/static")

      halt 400, 'Код зупинки має бути числом, на кшталт 128' if response.status == 400
      halt 404, erb(:not_found, layout: false, content_type: 'text/html') if response.status == 404
      halt 503, 'Сервіс тимчасово недоступний' unless response.success?

      parse_api_json(response)
    end

    # Trams and trolleybuses stopping within NEARBY_METRES of loc, from the stops there
    # other than code: the API lists a stop's transfers only for its own pole, and the
    # two kinds rarely share one. Decoration, so a failed or slow lookup gives none.
    def nearby_transfers(code, loc)
      return [] unless loc

      near = soft_api_json("/closest?latitude=#{loc[0].to_f}&longitude=#{loc[1].to_f}")
      Array(near).select do |s|
        s['code'].to_i != code.to_i && s['distance_meters'].to_f <= NEARBY_METRES &&
          Array(s['routes']).any? { |r| !r.to_s.match?(/\A[АAНN]/) }
      end.flat_map do |s|
        Array(soft_api_json("/stops/#{ERB::Util.url_encode(s['code'].to_s)}/static")&.fetch('transfers', nil))
      end
    end

    def soft_api_json(path)
      response = Faraday.get("#{ENV['API_URL'] || 'https://api.lad.lviv.ua'}#{path}") do |req|
        req.options.open_timeout = NEARBY_TIMEOUT
        req.options.timeout = NEARBY_TIMEOUT
      end
      response.success? ? JSON.parse(response.body) : nil
    rescue StandardError => e
      warn "nearby lookup failed for #{path}: #{e.class}: #{e.message}"
      nil
    end

    def load_route(route_id)
      response = api_get("/routes/static/#{ERB::Util.url_encode(route_id)}")
      halt 503, 'Сервіс тимчасово недоступний' unless response.success?

      parse_api_json(response)
    end
  end

  # The 2026 network drawing taken whole, with only the per-stop layer on top.
  get '/:code/schema' do
    stop_code = params['code']

    data = load_stop(stop_code)
    cache_at_edge
    data = apply_route_overrides(data, only: params['only'], add: params['add'], remove: params['remove'])
    transfers = get_transfers(data)

    data['name_en'] = eng_name_for(stop_code, data['eng_name'])

    erb :scheme,
    :locals => {
      data: data,
      transfers: transfers,
      # Off unless asked for: ?fade=1 dims the lines that do not serve this stop.
      fade: %w[1 true yes on].include?(params['fade'].to_s.downcase),
      spot: map_spot_for(stop_code, data['name'], data['transfers']),
      qrcode: qr_svg(stop_code)
    },
    content_type: 'image/svg+xml'
  end

  # The plate that goes inside the shelter: code, QR and name on one strip.
  # Shelters 4 m long take a 3000 mm plate, 5 m and longer take 4000 mm.
  get '/:code/panel' do
    stop_code = params['code']

    data = load_stop(stop_code)
    cache_at_edge
    data['name_en'] = eng_name_for(stop_code, data['eng_name'])

    erb :panel,
    :locals => {
      data: data,
      stop_code: stop_code,
      width: params['length'].to_s == '4' ? 3000 : 4000,
      qrcode: qr_svg(stop_code)
    },
    content_type: 'image/svg+xml'
  end

  # The departures sheet for one route from this stop (?route=Т03, else the first route
  # with departures here): hours by minutes for workdays and weekends, and the stops
  # ahead with minutes to each. The API lists departures only for a line's terminals.
  get '/:code/schedule' do
    stop_code = params['code']

    data = load_stop(stop_code)
    cache_at_edge
    wanted = params['route'].to_s.strip.empty? ? nil : normalize_route_name(params['route'])

    sheet = nil
    Array(data['transfers']).each do |t|
      next if wanted && normalize_route_name(t['route']) != wanted

      sheet = schedule_for(data['code'] || stop_code, t, load_route(t['id']))
      if sheet
        t['route_normalized'] = normalize_route_name(t['route'])
        sheet[:transfer] = t
        break
      end
    end
    halt 404, 'Для цієї зупинки немає розкладу відправлень' unless sheet

    rows = [sheet[:here], *sheet[:next_stops]]
    lookups = rows.map { |row| Thread.new { nearby_transfers(row['code'], row['loc']) } }
    deadline = Time.now + NEARBY_DEADLINE
    rows.zip(lookups) do |row, lookup|
      row['nearby'] = lookup.join([deadline - Time.now, 0].max) ? lookup.value : []
    end

    data['name_en'] = eng_name_for(stop_code, data['eng_name'])

    erb :schedule,
    :locals => { data: data, sheet: sheet },
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
    cache_at_edge
    data = apply_route_overrides(data, only: params['only'], add: params['add'], remove: params['remove'])
    transfers = get_transfers(data)

    n = detect_layout(transfers)

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
    data['name'] = data['name'].to_s.sub(/\A./, &:upcase)

    erb "layout-#{n}".to_sym,
    :locals => {
      data: data,
      transfers: transfers,
      qrcode: qr_svg(stop_code),
    },
    content_type: 'image/svg+xml'
  end

end

App.run! if __FILE__ == $0
