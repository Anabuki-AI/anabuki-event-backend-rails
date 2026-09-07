FROM ruby:3.4.7-slim AS base
WORKDIR /app
ENV BUNDLE_DEPLOYMENT=1 BUNDLE_WITHOUT="development:test"
RUN apt-get update -qq && apt-get install --no-install-recommends -y build-essential libpq-dev && rm -rf /var/lib/apt/lists/*

FROM base AS build
COPY Gemfile Gemfile.lock ./
RUN bundle install
COPY . .

FROM ruby:3.4.7-slim
WORKDIR /app
ENV RAILS_ENV=production RAILS_LOG_TO_STDOUT=true BUNDLE_DEPLOYMENT=1 BUNDLE_WITHOUT="development:test"
RUN apt-get update -qq && apt-get install --no-install-recommends -y libpq5 && rm -rf /var/lib/apt/lists/*
COPY --from=build /usr/local/bundle /usr/local/bundle
COPY --from=build /app /app
EXPOSE 8080
CMD ["sh", "-c", "bundle exec rails db:prepare && bundle exec rails server -b 0.0.0.0 -p ${PORT:-8080}"]
