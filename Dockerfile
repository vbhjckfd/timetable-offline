FROM ruby:3.3-alpine

# Change to the application's directory
ENV APP_HOME=/application
RUN mkdir $APP_HOME
WORKDIR $APP_HOME

# Skip test-only gems (rspec, webmock, rack-test) in the production image
ENV BUNDLE_WITHOUT=test

ADD Gemfile* $APP_HOME/

RUN apk add build-base && bundle install && apk del build-base && rm -rf /var/cache/apk/* /usr/local/bundle/cache

ADD . $APP_HOME

EXPOSE 4567

ENTRYPOINT ["sh", "-c", "./entrypoint.sh"]
