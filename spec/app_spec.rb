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

  def valid_body(transfers: nil)
    transfers ||= [
      { 'route' => '14', 'vehicle_type' => 'tram', 'end_stop_code' => 1 }
    ]
    { 'name' => 'Дитяча залізниця', 'code' => 1, 'transfers' => transfers }.to_json
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

    context 'error handling' do
      it 'returns 400 when the API returns 400' do
        stub_request(:get, "#{API_BASE}/stops/abc/static").to_return(status: 400, body: '')
        get '/abc'
        expect(last_response.status).to eq(400)
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

  # ── QR code generation ──────────────────────────────────────────────────────

  describe 'QR code generation' do
    before { stub_stop(body: valid_body) }

    it 'embeds an SVG QR code in the layout' do
      get "/#{STOP_CODE}"
      expect(last_response.body).to include('lad.lviv.ua')
    end
  end
end
