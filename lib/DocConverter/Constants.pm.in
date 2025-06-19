#!/usr/bin/env perl
package DocConverter::Constants;

use strict;
use warnings;

use Log::Log4perl::Level;

use Readonly;

Readonly::Scalar our $TRUE  => 1;
Readonly::Scalar our $FALSE => 0;

Readonly::Scalar our $DASH  => q{-};
Readonly::Scalar our $SLASH => q{/};
Readonly::Scalar our $SPACE => q{ };
Readonly::Scalar our $EMPTY => q{};

Readonly::Scalar our $HTTP_NOT_FOUND    => '404';
Readonly::Scalar our $HTTP_OK           => '200';
Readonly::Scalar our $HTTP_SERVER_ERROR => '500';
Readonly::Scalar our $HTTP_BAD_REQUEST  => '400';

Readonly::Scalar our $DEFAULT_TIMEOUT        => 60;
Readonly::Scalar our $DEFAULT_SLEEP_INTERVAL => 1;
Readonly::Scalar our $BUFFER_SIZE            => 4096;

Readonly::Hash our %LOG_LEVELS => (
  trace => $TRACE,
  debug => $DEBUG,
  warn  => $WARN,
  info  => $INFO,
  error => $ERROR,
);

our %MIME_TYPES = (
  'application/pdf'                                                          => '.pdf',
  'image/jpeg'                                                               => '.jpg',
  'image/png'                                                                => '.png',
  'application/vnd-ms-excel'                                                 => '.xls',
  'application/msword'                                                       => '.doc',
  'application/vnd.openxmlformats-officeodocument.wordprocessingml.document' => '.docx',
  'application/vnd.openxmlformats-officeodocument.spreadhseetml.sheet'       => '.xlsx',
);

use parent qw(Exporter);

our @EXPORT = qw(
  $TRUE
  $FALSE
  $DASH
  $SLASH
  $SPACE
  $EMPTY
  %MIME_TYPES
  $HTTP_NOT_FOUND
  $HTTP_OK
  $HTTP_SERVER_ERROR
  $DEFAULT_TIMEOUT
  $DEFAULT_SLEEP_INTERVAL
  $BUFFER_SIZE
  %LOG_LEVELS
);

1;
