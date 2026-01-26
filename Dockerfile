FROM ruby:3.2
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:UTF-8 LC_ALL=C.UTF-8

RUN apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y --no-install-recommends \
        libraptor2-0 \
        cron \
        git && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir /server
WORKDIR /server

RUN gem update --system --no-document && \
    gem install bundler:2.3.12 --no-document

# === CHANGED SECTION ===
COPY Gemfile Gemfile.lock fdp_index_proxy.gemspec /server/
COPY lib/ /server/lib/                        
RUN bundle config set --local without 'development test' && \
    bundle install
# === END CHANGED ===

# Copy the rest of the application source
COPY . /server/

# Set up cron job...
RUN echo "0 0 * * 0 curl http://localhost:4567/fdp-index-proxy/ping >> /var/log/cron.log 2>&1" > /etc/cron.d/weekly-job && \
    chmod 0644 /etc/cron.d/weekly-job && \
    crontab /etc/cron.d/weekly-job && \
    touch /var/log/cron.log

ENTRYPOINT ["sh", "/server/entrypoint.sh"]