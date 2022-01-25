FROM ruby:2.5.9-slim

# Change to the application's directory
ENV APP_HOME /application
RUN mkdir $APP_HOME
WORKDIR $APP_HOME

ADD Gemfile* $APP_HOME/

RUN bundle config set without 'development test' && bundle install

ADD . $APP_HOME

EXPOSE 4567

ENTRYPOINT ["sh", "-c", "./entrypoint.sh"]
