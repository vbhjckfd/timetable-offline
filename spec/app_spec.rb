require 'spec_helper'

RSpec.describe App do
  def app
    App
  end

  # Stop code 1 is present in ENG_NAMES ("Children's railway"), avoiding nil crash
  STOP_CODE = '1'
  API_STOP_URL = "#{API_BASE}/stops/#{STOP_CODE}/static"

  def stub_stop(body:, status: 200)
    stub_request(:get, API_STOP_URL)
      .to_return(status: status, body: body, headers: { 'Content-Type' => 'application/json' })
  end

  def valid_body(transfers: nil, **extra)
    transfers ||= [
      { 'route' => '14', 'vehicle_type' => 'tram', 'end_stop_code' => 1 }
    ]
    { 'name' => 'Дитяча залізниця', 'code' => 1, 'transfers' => transfers }
      .merge(extra.transform_keys(&:to_s))
      .to_json
  end

  # ── GET /:code ──────────────────────────────────────────────────────────────

  describe 'GET /:code' do
    context 'with a valid stop' do
      before { stub_stop(body: valid_body) }

      it 'returns 200' do
        get "/#{STOP_CODE}"
        expect(last_response.status).to eq(200)
      end

      it 'returns SVG content type' do
        get "/#{STOP_CODE}"
        expect(last_response.content_type).to include('image/svg+xml')
      end

      it 'sets X-Robots-Tag: noindex, nofollow' do
        get "/#{STOP_CODE}"
        expect(last_response.headers['X-Robots-Tag']).to eq('noindex, nofollow')
      end

      it 'renders an SVG document' do
        get "/#{STOP_CODE}"
        expect(last_response.body).to include('<svg')
        expect(last_response.body).to include('</svg>')
      end

      it 'includes the stop code in the SVG body' do
        get "/#{STOP_CODE}"
        expect(last_response.body).to include(STOP_CODE)
      end
    end

    context 'layout-3: one type with ≤3 routes' do
      before do
        stub_stop(body: valid_body(transfers: [
          { 'route' => '3', 'vehicle_type' => 'tram', 'end_stop_code' => 1 }
        ]))
      end

      it 'returns 200 and renders without error' do
        get "/#{STOP_CODE}"
        expect(last_response.status).to eq(200)
        expect(last_response.body).to include('<svg')
      end
    end

    context 'layout-8: two types within capacity' do
      before do
        stub_stop(body: valid_body(transfers: [
          { 'route' => '3',  'vehicle_type' => 'tram', 'end_stop_code' => 1 },
          { 'route' => '5',  'vehicle_type' => 'tram', 'end_stop_code' => 2 },
          { 'route' => '32', 'vehicle_type' => 'bus',  'end_stop_code' => 3 },
          { 'route' => '14', 'vehicle_type' => 'bus',  'end_stop_code' => 4 },
        ]))
      end

      it 'returns 200 and renders without error' do
        get "/#{STOP_CODE}"
        expect(last_response.status).to eq(200)
        expect(last_response.body).to include('<svg')
      end
    end

    context 'API "trolleybus" vehicle_type (real payload for stops 80/81)' do
      before do
        stub_stop(body: valid_body(transfers: [
          { 'route' => 'А03', 'vehicle_type' => 'bus',        'end_stop_code' => 320 },
          { 'route' => 'А18', 'vehicle_type' => 'bus',        'end_stop_code' => 177 },
          { 'route' => 'А57', 'vehicle_type' => 'bus',        'end_stop_code' => 417 },
          { 'route' => 'Т25', 'vehicle_type' => 'trolleybus', 'end_stop_code' => 62 },
        ]))
      end

      it 'returns 200 and renders without error' do
        get "/#{STOP_CODE}"
        expect(last_response.status).to eq(200)
        expect(last_response.body).to include('<svg')
        expect(last_response.body).to include('/icons/t25.svg')
      end
    end

    context 'layout-28: many routes across multiple types' do
      before do
        bus_routes = (10..23).map { |n| { 'route' => n.to_s, 'vehicle_type' => 'bus', 'end_stop_code' => 1 } }
        stub_stop(body: valid_body(transfers: bus_routes + [
          { 'route' => '3',  'vehicle_type' => 'tram', 'end_stop_code' => 2 },
          { 'route' => '34', 'vehicle_type' => 'trol', 'end_stop_code' => 3 },
        ]))
      end

      it 'returns 200 and renders without error' do
        get "/#{STOP_CODE}"
        expect(last_response.status).to eq(200)
        expect(last_response.body).to include('<svg')
      end
    end

    context 'layout-28: 22 bus routes (needs a 4th grid row)' do
      before do
        stub_stop(body: valid_body(transfers: (1..22).map do |n|
          { 'route' => n.to_s, 'vehicle_type' => 'bus', 'end_stop_code' => 1 }
        end))
      end

      it 'returns 200 and renders without error' do
        get "/#{STOP_CODE}"
        expect(last_response.status).to eq(200)
        expect(last_response.body).to include('<svg')
      end

      it 'renders all 22 route icons' do
        get "/#{STOP_CODE}"
        # Routes 1-6 normalise to 1a-6a, the rest keep their bare number.
        expect(last_response.body.scan(%r{/icons/\d+[a-z]?\.svg}).length).to eq(22)
      end

      it 'places the 22nd route on a 4th row clear of the QR block at y 3172' do
        get "/#{STOP_CODE}"
        # 4th row top = 3378.22 - 295.28, rendered as a float.
        expect(last_response.body).to match(/y="3082\.9\d*"/)
      end
    end

    context 'error handling' do
      it 'returns 400 when the API returns 400' do
        stub_request(:get, "#{API_BASE}/stops/abc/static").to_return(status: 400, body: '')
        get '/abc'
        expect(last_response.status).to eq(400)
      end

      it 'returns 503 when the API returns 500' do
        stub_stop(body: 'upstream boom', status: 500)
        get "/#{STOP_CODE}"
        expect(last_response.status).to eq(503)
      end

      it 'returns 503 when the API connection times out' do
        stub_request(:get, API_STOP_URL).to_timeout
        get "/#{STOP_CODE}"
        expect(last_response.status).to eq(503)
      end

      it 'returns 404 when the API returns 404' do
        stub_request(:get, "#{API_BASE}/stops/9999/static").to_return(status: 404, body: '')
        get '/9999'
        expect(last_response.status).to eq(404)
      end

      it 'returns 503 when the API response is not valid JSON' do
        stub_stop(body: 'not json at all')
        get "/#{STOP_CODE}"
        expect(last_response.status).to eq(503)
      end
    end

    context 'stop name cleaning' do
      it 'strips known suburb prefixes' do
        body = { 'name' => 'Рудне, Центр', 'code' => 1, 'transfers' => [
          { 'route' => '14', 'vehicle_type' => 'tram', 'end_stop_code' => 1 }
        ] }.to_json
        stub_stop(body: body)
        get "/#{STOP_CODE}"
        expect(last_response.body).not_to include('Рудне,')
        expect(last_response.body).to include('Центр')
      end
    end
  end

  # ── GET /:code/schema ───────────────────────────────────────────────────────

  describe 'GET /:code/schema' do
    context 'with a valid stop' do
      before { stub_stop(body: valid_body) }

      it 'returns 200' do
        get "/#{STOP_CODE}/schema"
        expect(last_response.status).to eq(200)
      end

      it 'returns SVG content type' do
        get "/#{STOP_CODE}/schema"
        expect(last_response.content_type).to include('image/svg+xml')
      end

      it 'sets X-Robots-Tag: noindex, nofollow' do
        get "/#{STOP_CODE}/schema"
        expect(last_response.headers['X-Robots-Tag']).to eq('noindex, nofollow')
      end

      it 'renders an SVG document' do
        get "/#{STOP_CODE}/schema"
        expect(last_response.body).to include('<svg')
        expect(last_response.body).to include('</svg>')
      end

      it 'includes the English stop name' do
        get "/#{STOP_CODE}/schema"
        expect(last_response.body).to include("Children's railway")
      end
    end

    context 'English stop name resolution' do
      # 182 of the API's 993 stops are absent from eng_names.rb; this used to
      # raise NoMethodError on nil and 500.
      it 'renders a stop that is in neither the API nor eng_names.rb' do
        stub_request(:get, "#{API_BASE}/stops/999999/static")
          .to_return(status: 200, body: valid_body, headers: { 'Content-Type' => 'application/json' })

        get '/999999/schema'
        expect(last_response.status).to eq(200)
        expect(last_response.body).to include('<svg')
      end

      it 'uses the API eng_name for a stop missing from eng_names.rb' do
        stub_request(:get, "#{API_BASE}/stops/999999/static")
          .to_return(status: 200, body: valid_body(eng_name: 'Brand New Stop'),
                     headers: { 'Content-Type' => 'application/json' })

        get '/999999/schema'
        expect(last_response.body).to include('Brand New Stop')
      end

      # eng_names.rb has stop 1 as "Children's railway"; the API wins.
      it 'prefers the API eng_name over the stale eng_names.rb entry' do
        stub_stop(body: valid_body(
          eng_name: 'Lem Square',
          transfers: [{ 'route' => '14', 'vehicle_type' => 'tram', 'end_stop_code' => 999999 }]
        ))

        get "/#{STOP_CODE}/schema"
        expect(last_response.body).to include('Lem Square')
        expect(last_response.body).not_to include("Children's railway")
      end

      it 'prefers the API end_stop_eng_name over the stale eng_names.rb entry' do
        stub_stop(body: valid_body(transfers: [
          { 'route' => '14', 'vehicle_type' => 'tram', 'end_stop_code' => 1,
            'end_stop_eng_name' => 'Renamed Terminus' }
        ]))

        get "/#{STOP_CODE}/schema"
        expect(last_response.body).to include('Renamed Terminus')
      end
    end

    context 'error handling' do
      it 'returns 400 when the API returns 400' do
        stub_request(:get, "#{API_BASE}/stops/abc/static").to_return(status: 400, body: '')
        get '/abc/schema'
        expect(last_response.status).to eq(400)
      end

      it 'returns 404 when the API returns 404' do
        stub_request(:get, "#{API_BASE}/stops/9999/static").to_return(status: 404, body: '')
        get '/9999/schema'
        expect(last_response.status).to eq(404)
      end

      it 'returns 503 when the API response is not valid JSON' do
        stub_stop(body: 'not json')
        get "/#{STOP_CODE}/schema"
        expect(last_response.status).to eq(503)
      end
    end
  end

  # ── upstream request construction ───────────────────────────────────────────

  describe 'upstream URL construction' do
    it 'percent-encodes the stop code instead of interpolating it raw' do
      escaped = stub_request(:get, "#{API_BASE}/stops/%D0%90/static")
                  .to_return(status: 404, body: '')

      get '/%D0%90' # Cyrillic А

      expect(last_response.status).to eq(404)
      expect(escaped).to have_been_requested
    end

    # Sinatra 4 mounts Rack::Protection::PathTraversal, which normalises the
    # path before routing, so ../ never reaches params. url_encode is the second
    # layer, in case that middleware is ever dropped.
    it 'does not let an encoded ../ reach the upstream path' do
      stub_request(:get, %r{#{API_BASE}/stops/.*/static}).to_return(status: 404, body: '')

      get '/..%2F..%2Fadmin'

      expect(WebMock).not_to have_requested(:get, %r{/stops/\.\.})
    end
  end

  # ── SVG well-formedness ─────────────────────────────────────────────────────

  describe 'SVG output' do
    before do
      stub_stop(body: valid_body(transfers: (1..12).map do |n|
        { 'route' => n.to_s, 'vehicle_type' => 'bus', 'end_stop_code' => 1 }
      end))
    end

    it 'emits no empty transform values' do
      get "/#{STOP_CODE}"
      expect(last_response.body).not_to include('translate(0, )')
    end
  end

  # ── QR code generation ──────────────────────────────────────────────────────

  describe 'QR code generation' do
    before { stub_stop(body: valid_body) }

    it 'embeds an SVG QR code in the layout' do
      get "/#{STOP_CODE}"
      expect(last_response.body).to include('lad.lviv.ua')
    end
  end
end
