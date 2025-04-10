#!/bin/sh
service cron start
/usr/local/bin/ruby /server/fdp_index_proxy/application/controllers/application_controller.rb -o 0.0.0.0
