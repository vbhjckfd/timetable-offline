.DEFAULT_GOAL := up
.PHONY: up build-gemfile build

# Refresh Gemfile.lock inside ruby:3.1-alpine (same as CI/Docker).
build-gemfile:
	./build-gemfilelock.sh

# Build linux/amd64 image and push to gcr.io (production).
build:
	./build.sh

# Runs build-gemfilelock.sh, build.sh, then docker-compose up --build.
up: build-gemfile build
	docker-compose up --build
