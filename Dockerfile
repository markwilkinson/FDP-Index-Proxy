FROM ruby:3.3.0
#FROM ruby:3.2.2-alpine3.17

ENV LANG="en_US.UTF-8" LANGUAGE="en_US:UTF-8" LC_ALL="C.UTF-8"
#RUN chmod a+r /etc/resolv.conf

USER root
RUN apt-get -y update && apt-get -y upgrade 
RUN apt-get -y update
RUN apt-get install -y libraptor2-0 
# RUN apk update && apk upgrade && apk add --update alpine-sdk && \
    # apk add --no-cache bash make cmake


RUN mkdir /server
WORKDIR /server
RUN gem update --system
RUN gem install bundler:2.3.12
COPY . /server
WORKDIR /server/fdp_index_proxy
RUN bundle install
