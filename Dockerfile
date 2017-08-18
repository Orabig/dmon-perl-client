FROM perl:latest

MAINTAINER benoit.chauvet@gmail.com

RUN cpanm Config::JSON REST::Client AnyEvent::HTTP AnyEvent::Open3::Simple Centrifugo::Client
