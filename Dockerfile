FROM ruby:3.3.0

ENV LANG="en_US.UTF-8" LANGUAGE="en_US:UTF-8" LC_ALL="C.UTF-8"

USER root
RUN apt-get -y update && apt-get -y upgrade 
RUN apt-get -y update
RUN apt-get install -y libraptor2-0 cron

RUN mkdir /server
WORKDIR /server
RUN gem update --system
RUN gem install bundler:2.3.12
COPY ./ /server
WORKDIR /server
RUN bundle install
WORKDIR /server/fdp_index_proxy

# Create a cron job file
# RUN echo "0 0 * * 0 /usr/local/bin/ruby /app/your_script.rb >> /var/log/cron.log 2>&1" > /etc/cron.d/weekly-job
RUN echo "0 0 * * 0 curl http://localhost:4000/fdp-index-proxy/ping >> /var/log/cron.log 2>&1" > /etc/cron.d/weekly-job

# Install the cron job
RUN crontab /etc/cron.d/weekly-job

# Create a log file for cron
RUN touch /var/log/cron.log
