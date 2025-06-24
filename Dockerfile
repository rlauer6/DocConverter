FROM debian:bookworm

COPY bookworm-backports.list /etc/apt/sources.list.d/

RUN apt-get update --fix-missing && apt-get install -y --fix-missing \
    less vim curl git automake less gcc gnupg libzip-dev \
    apache2 apache2-dev libpcre3 libapr1-dev libaprutil1-dev \
    libssl-dev libperl-dev perl-doc \
    libpng-dev libexpat-dev imagemagick libreoffice poppler-utils ghostscript \
    libapache2-mod-perl2 libapache2-mod-perl2-dev libapache2-mod-apreq2

RUN curl -L https://cpanmin.us | perl - App::cpanminus
RUN cpanm -n ExtUtils::XSBuilder::ParseSource

# install deps
COPY requires /
RUN for a in $(cat requires|awk '{print $1}');do \
      cpanm -n -v $a; \
    done

COPY SQS-Queue-Worker-*.tar.gz .
RUN cpanm -n -v SQS-Queue-Worker-*.tar.gz

COPY DocConverter-*.tar.gz .
RUN cpanm -n -v DocConverter-*.tar.gz

RUN apt-get autoremove --fix-missing -yq && rm -rf /var/lib/apt/lists/*

RUN a2dismod mpm_event
RUN a2enmod mpm_prefork
RUN a2enmod cgi
RUN a2enmod rewrite
RUN a2enmod actions

RUN echo "LoadModule perl_module /usr/lib/apache2/modules/mod_perl.so" >/etc/apache2/mods-available/perl.load
RUN a2enmod perl

RUN DIST_DIR=$(perl -MFile::ShareDir -e 'print File::ShareDir::dist_dir(q{DocConverter});'); \
    cp $DIST_DIR/*.conf /etc/apache2/conf-available/; \
    a2enconf doc-converter

RUN cp /usr/local/bin/doc-converter.pl /usr/lib/cgi-bin/doc-converter.cgi
RUN sed -ibak 's/rights="none" pattern="PDF"/rights="read|write" pattern="PDF"/' /etc/ImageMagick-6/policy.xml
CMD ["/usr/sbin/apache2ctl", "-D", "FOREGROUND" ]
