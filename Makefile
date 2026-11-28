.DEFAULT_GOAL := up
.PHONY: up build-gemfile build test deploy clear-cache

PROJECT := timetable-252615
REGION  := europe-north1
SERVICE := timetable-offline
IMAGE   := $(REGION)-docker.pkg.dev/$(PROJECT)/timetable/$(SERVICE)

# Refresh Gemfile.lock inside ruby:3.3-alpine (same as CI/Docker).
build-gemfile:
	./build-gemfilelock.sh

# Build linux/amd64 image and push to Artifact Registry (production).
build:
	./build.sh

# Run the rspec suite inside ruby:3.3-alpine.
test:
	docker run --rm -v $(PWD):/app -w /app ruby:3.3-alpine \
		sh -c "apk add --no-cache build-base >/dev/null && bundle install --quiet && bundle exec rspec"

# Build + push the image, then roll it out to Cloud Run.
# `build.sh` only pushes the image; without this the service keeps serving the old revision.
deploy: build
	gcloud run deploy $(SERVICE) \
		--project $(PROJECT) \
		--region $(REGION) \
		--image $(IMAGE):latest \
		--platform managed
	gcloud run services describe $(SERVICE) \
		--project $(PROJECT) --region $(REGION) \
		--format 'value(status.url,status.latestReadyRevisionName)'
	$(MAKE) clear-cache

# Runs build-gemfilelock.sh, build.sh, then docker-compose up --build.
up: build-gemfile build
	docker-compose up --build

# Purge only responses tagged Cache-Tag: svg; a full purge would drop other hosts in the zone.
CLOUDFLARE_CACHE_CLEAR_URL ?= https://drop-cloudflare-cache-1041251696619.us-central1.run.app
clear-cache:
	curl -sS "$(CLOUDFLARE_CACHE_CLEAR_URL)?tags=svg"
