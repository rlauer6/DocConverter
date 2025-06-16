package DocConverter::Utils;

# Utilities for the client/server portions of the doc-converter project

# Copyright (C) 2025 TBC Development Group, LLC
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or (at
# your option) any later version.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

use strict;
use warnings;

use Amazon::S3;
use Data::Dumper;
use DocConverter::Constants;
use File::Basename;
use File::HomeDir;
use File::Temp qw(tempfile tempdir);
use Log::Log4perl::Level;
use HTTP::Request;
use LWP::UserAgent;
use JSON;

use parent qw(Exporter);

our @EXPORT = qw(
  put_to_s3
  get_from_s3
  list_bucket
  $LOGGER
  $LOG_LEVEL
);

our $LOGGER;
our $LOG_LEVEL;

########################################################################
sub init_logger {
########################################################################
  my ($level) = @_;

  $LOG_LEVEL = $LOG_LEVELS{ lc $level } // $INFO;

  Log::Log4perl->easy_init($LOG_LEVEL);
  $LOGGER = Log::Log4perl->get_logger();

  return $LOGGER;
}

########################################################################
sub put_to_s3 {
########################################################################
  my ( $bucket, $document_id, $file ) = @_;

  my ( $key, undef, $ext ) = fileparse( $file, qr/[.][^.]*$/xsm );

  my $rsp = $bucket->add_key_filename( "$document_id/$key$ext", $file );

  return $rsp ? $file : undef;
}

########################################################################
sub get_from_s3 {
########################################################################
  my ( $bucket, $document_id, $file ) = @_;

  my $dir = tempdir( CLEANUP => $TRUE );

  my $outfile = sprintf '%s/%s', $dir, $file;

  my $rsp = $bucket->get_key_filename( "$document_id/$file", undef, $outfile );

  return -s $outfile ? $outfile : $EMPTY;
}

########################################################################
sub list_bucket {
########################################################################
  my ( $bucket, $document_id ) = @_;

  return $bucket->list( { prefix => $document_id } );
}

1;

__END__

=pod

=head1 NAME

DocConverter::Utils

=head1 SYNOPSIS

 use DocConverter::Utils qw/put_to_s3/;

 put_to_s3( $bucket, $document_id, $file );

 get_from_s3( $bucket, $document_id, $file );

 list_bucket( $bucket );

 my $creds = get_ec2_credentials();

=head1 DESCRIPTION

A set of common utilities, some of which are used by both the client
(C<doc2pdf-client>) and the server (C<doc-converter.cgi>).

=head1 METHODS AND SUBROUTINES

=head2 put_to_s3

 put_to_s3( bucket, document-id, file )

Send a file to an S3 bucket. Returns the bucket key if successful. The
file is stored in the S3 bucket with a key prefix of
C<document-id>. The C<document-id> is typically a GUID.

 my $ug = Data::UUID;
 my $uuid = $ug->create;

 put_to_s3( $bucket, $ug->to_string($uuid), 'somefile.txt' );


=over 5

=item bucket

An C<Amazon::S3::Bucket> object.  The file will be uploaded to the
bucket the prefix C<document-id>.

=item document-id

A document identifier (usually a GUID) that is used as the bucket
prefix for the file.  The file is then stored with the key
C<document-id/filename>.

=item file

Fully qualified path to the file to be uploaded.

=back

=cut

=pod

=head1 AUTHOR

Rob Lauer - <rlauer6@comcast.net>

=head1 LICENSE

GNU General Public License v3.0

Copyright (C) 2025, TBC DevelopmentGroup, LLC
All rights reserved

=cut

1;
