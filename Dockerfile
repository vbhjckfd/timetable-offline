# Build stage: compile native gems, then strip Ruby down to what the server runs.
FROM ruby:3.3-alpine AS build

# Skip test-only gems (rspec, webmock, rack-test) in the production image
ENV BUNDLE_WITHOUT=test

RUN apk add --no-cache build-base

COPY Gemfile Gemfile.lock ./
RUN bundle install --jobs 4

# Compiled extensions are already copied into lib/, so sources, objects and gem
# caches go; so do Ruby's headers, static lib, docs and the dev-only bundled gems.
RUN cd /usr/local/bundle \
 && rm -rf cache gems/*/ext gems/*/spec gems/*/test gems/*/docs \
 && find . \( -name '*.o' -o -name '*.c' -o -name '*.h' -o -name 'Makefile' -o -name 'mkmf.log' -o -name 'gem_make.out' \) -delete \
 && rm -rf /usr/local/include /usr/local/share /usr/local/lib/*.a /usr/local/lib/pkgconfig \
 && cd /usr/local/lib/ruby/gems/3.3.0 \
 && rm -rf cache doc \
 && for g in debug irb minitest power_assert rake rbs rdoc reline readline test-unit typeprof net-ftp net-imap net-pop net-smtp rss rinda prime matrix; do \
      rm -rf gems/$g-[0-9]* specifications/$g-[0-9]*.gemspec; \
    done

# Runtime stage: bare Alpine (same release as the Ruby image) plus Ruby's runtime libs.
FROM alpine:3.24

RUN apk add --no-cache gmp libffi libgcc yaml zlib ca-certificates

COPY --from=build /usr/local /usr/local

ENV LANG=C.UTF-8 \
    GEM_HOME=/usr/local/bundle \
    BUNDLE_SILENCE_ROOT_WARNING=1 \
    BUNDLE_APP_CONFIG=/usr/local/bundle \
    BUNDLE_WITHOUT=test \
    PATH=/usr/local/bundle/bin:$PATH

ENV APP_HOME=/application
WORKDIR $APP_HOME
COPY . $APP_HOME

EXPOSE 4567

ENTRYPOINT ["sh", "-c", "./entrypoint.sh"]
