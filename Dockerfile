FROM ruby:3.4.7-slim AS base
WORKDIR /app
ENV BUNDLE_DEPLOYMENT=1
RUN apt-get update -qq && apt-get install --no-install-recommends -y build-essential libpq-dev postgresql-client && rm -rf /var/lib/apt/lists/*

FROM base AS development-build
ENV BUNDLE_WITHOUT=""
COPY Gemfile Gemfile.lock ./
RUN bundle install
COPY . .

FROM base AS development
ENV RAILS_ENV=development BUNDLE_WITHOUT=""
COPY --from=development-build /usr/local/bundle /usr/local/bundle
COPY --from=development-build /app /app
EXPOSE 8080
CMD ["bundle", "exec", "rails", "server", "-b", "0.0.0.0", "-p", "8080"]

FROM base AS production-build
ENV BUNDLE_WITHOUT="development:test"
COPY Gemfile Gemfile.lock ./
RUN bundle install
COPY . .

FROM ruby:3.4.7-slim AS production
WORKDIR /app
ENV RAILS_ENV=production RAILS_LOG_TO_STDOUT=true BUNDLE_DEPLOYMENT=1 BUNDLE_WITHOUT="development:test"
RUN apt-get update -qq && apt-get install --no-install-recommends -y libpq5 postgresql-client && rm -rf /var/lib/apt/lists/*
COPY --from=production-build /usr/local/bundle /usr/local/bundle
COPY --from=production-build /app /app
EXPOSE 8080
CMD ["sh", "-c", "bundle exec rails db:prepare && bundle exec rails server -b 0.0.0.0 -p ${PORT:-8080}"]
