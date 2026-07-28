.DEFAULT_GOAL := up
.PHONY: up build-gemfile build test deploy

PROJECT := timetable-252615
REGION  := us-central1
SERVICE := timetable-offline
IMAGE   := gcr.io/$(PROJECT)/$(SERVICE)

# Refresh Gemfile.lock inside ruby:3.1-alpine (same as CI/Docker).
build-gemfile:
	./build-gemfilelock.sh

# Build linux/amd64 image and push to gcr.io (production).
build:
	./build.sh

# Run the rspec suite inside ruby:3.1-alpine.
test:
	docker run --rm -v $(PWD):/app -w /app ruby:3.1-alpine \
		sh -c "apk add --no-cache build-base >/dev/null && bundle install --quiet && bundle exec rspec"

# Build + push the image, then roll it out to Cloud Run.
# `build.sh` only updates gcr.io; without this the service keeps serving the old revision.
deploy: build
	gcloud run deploy $(SERVICE) \
		--project $(PROJECT) \
		--region $(REGION) \
		--image $(IMAGE):latest \
		--platform managed
	gcloud run services describe $(SERVICE) \
		--project $(PROJECT) --region $(REGION) \
		--format 'value(status.url,status.latestReadyRevisionName)'

# Runs build-gemfilelock.sh, build.sh, then docker-compose up --build.
up: build-gemfile build
	docker-compose up --build
