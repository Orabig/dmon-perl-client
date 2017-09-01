FROM perl:latest

MAINTAINER benoit.chauvet@gmail.com

RUN apt-get update \
    && apt-get install -y \
      libnet-ssleay-perl \
      libnet-http-perl \
    && rm -rf /var/lib/apt/lists/*

RUN cpanm -n --force REST::Client
RUN cpanm Config::JSON Data::UUID AnyEvent::HTTP AnyEvent::Open3::Simple Centrifugo::Client

RUN mkdir /opt/dmon
RUN git clone https://github.com/Orabig/dmon-perl-client /opt/dmon
RUN chmod a+rwX -R /opt/dmon
WORKDIR /opt/dmon
