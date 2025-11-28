FROM ruby:3.3.0

ENV LANG=en_US.UTF-8 LANGUAGE=en_US:UTF-8 LC_ALL=C.UTF-8

# Install system dependencies in a single layer, with cleanup for smaller image
RUN apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y --no-install-recommends \
        libraptor2-0 \
        cron \
        git && \
    rm -rf /var/lib/apt/lists/*

# Create app directory and update/install gems in one layer for better caching
RUN mkdir /server
WORKDIR /server
RUN gem update --system --no-document && \
    gem install bundler:2.3.12 --no-document

# Copy Gemfile* + gemspec + lib (for local gem eval) first for gem caching, then install dependencies
COPY Gemfile Gemfile.lock fdp_index_proxy.gemspec lib ./

# DEBUG: Verify lib/ and version.rb copied correctly (remove after fixing)
RUN echo "--- Listing root ---" && ls -la ./
RUN echo "--- Listing lib/ ---" && ls -la lib/ || echo "lib dir missing!"
RUN echo "--- Listing lib/fdp_index_proxy/ ---" && ls -la lib/fdp_index_proxy/ || echo "fdp_index_proxy subdir missing!"
RUN echo "--- Checking version.rb ---" && test -f lib/fdp_index_proxy/version.rb && (echo "version.rb FOUND!"; cat lib/fdp_index_proxy/version.rb) || echo "version.rb MISSING!"
RUN echo "--- Testing require_relative ---" && ruby -e "require_relative 'lib/fdp_index_proxy/version.rb'; puts 'SUCCESS: FdpIndexProxy::VERSION = ' + FdpIndexProxy::VERSION.to_s" || echo "require_relative FAILED!"

RUN bundle config set --local without 'development test' && \
    bundle install

# Copy the rest of the application source (including fdp_index_proxy/ app dir)
COPY . ./

# Switch to app subdirectory
WORKDIR /server/fdp_index_proxy

# Set up cron job in a single layer
RUN echo "0 0 * * 0 curl http://localhost:4567/fdp-index-proxy/ping >> /var/log/cron.log 2>&1" > /etc/cron.d/weekly-job && \
    chmod 0644 /etc/cron.d/weekly-job && \
    crontab /etc/cron.d/weekly-job && \
    touch /var/log/cron.log

ENTRYPOINT ["sh", "/server/entrypoint.sh"]