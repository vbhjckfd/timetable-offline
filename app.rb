require 'sinatra/base'
require 'faraday'
require 'rqrcode'
require 'base64'
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

def get_transfers(data)
  transfers = {
    bus: [],
    tram: [],
    trol: [],
    night: [],
  }

  data['transfers'].each do |t|
    if t['route'].start_with? 'Н'
      type = :night
    else
      type = VEHICLE_TYPES.fetch(t['vehicle_type'], :bus)
    end

    name = t['route'].downcase
    name = name.gsub(/[тан]/, 'т' => 't', 'а' => 'a', 'н' => 'n')
    name = name.gsub('a0', 'a')
    name = name.gsub('t0', 't')
    name = name.gsub('n0', 'n')
    name = name[1..-1] if name.chr == "a"
    name = 'airport' if name == "еропорt"
    name = name + "a" if ["1", "2", "3", "4", "5", "6", "36", "47"].include? name
    t['route_normalized'] = name

    t['eng_end_stop_name'] = eng_name_for(t['end_stop_code'], t['end_stop_eng_name'])

    transfers[type] << t
  end

  transfers = transfers.delete_if { |k, v| v.empty? }
end

class App < Sinatra::Base
  configure do
    set :server, :puma
    set :bind, '0.0.0.0'
  end

  before do
    headers 'X-Robots-Tag' => 'noindex, nofollow'
  end

  get '/:code/schema' do
    stop_code = params['code']
    api_url = ENV['API_URL'] || 'https://api.lad.lviv.ua'

    response = Faraday.get "#{api_url}/stops/#{stop_code}/static"

    halt response.status, "Код зупинки має бути числом, на кшталт 128" if response.status == 400
    halt response.status, "Неправильний код зупинки" if response.status == 404

    begin
      data = JSON.parse(response.body)
    rescue JSON::ParserError => e
      data = nil
    end
    halt 503 if data.nil?

    transfers = get_transfers(data)

    data['name_en'] = eng_name_for(stop_code, data['eng_name'])

    erb "scheme".to_sym,
    :locals => {
      data: data,
      transfers: transfers
    },
    content_type: 'image/svg+xml'
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
    api_url = ENV['API_URL'] || 'https://api.lad.lviv.ua'

    response = Faraday.get "#{api_url}/stops/#{stop_code}/static"

    halt response.status, "Код зупинки має бути числом, на кшталт 128" if response.status == 400
    halt response.status, "Неправильний код зупинки" if response.status == 404

    begin
      data = JSON.parse(response.body)
    rescue JSON::ParserError => e
      data = nil
    end
    halt 503 if data.nil?

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
    ].each {|s| data['name'] = data['name'].sub(s, '') }
    data['name'] = data['name'].upcase_first

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
