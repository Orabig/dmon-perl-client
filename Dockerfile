FROM perl:latest

MAINTAINER benoit.chauvet@gmail.com

RUN cpanm Centrifugo::Client Config::JSON REST::Client AnyEvent::Open3::Simple
