FROM ruby:3.1-alpine

# Change to the application's directory
ENV APP_HOME /application
RUN mkdir $APP_HOME
WORKDIR $APP_HOME

ADD Gemfile* $APP_HOME/

RUN apk add build-base && bundle install && apk del build-base linux-headers pcre-dev openssl-dev && rm -rf /var/cache/apk/*

ADD . $APP_HOME

EXPOSE 4567

ENTRYPOINT ["sh", "-c", "./entrypoint.sh"]
