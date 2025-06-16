#!/usr/bin/env perl

# Document converter - converts .xls[x], .doc[x] to .pdf

# Copyright (C) 2025, TBC DevelopmentGroup, LLC
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
use Amazon::Credentials;
use Carp;
use Data::Dumper;
use Data::UUID;
use Date::Manip::Date;
use DocConverter::Utils;
use DocConverter::Constants;
use English qw(-no_match_vars);
use File::Basename;
use File::Temp qw(tempdir tempfile);
use File::ShareDir qw(dist_dir);
use JSON;
use Scalar::Util qw(reftype);
use Time::HiRes qw(gettimeofday tv_interval);

########################################################################
sub pdfinfo {
########################################################################
  my ( $file, $config ) = @_;

  croak "no config object\n"
    if reftype $config ne 'HASH' || !defined $config->{helpers};

  my $cmd = sprintf '%s %s', $config->{helpers}->{pdfinfo}, $file;
  $LOGGER->info( 'command: ' . $cmd );

  open my $fh, "$cmd|"
    or die $OS_ERROR;

  my $pages;

  while (<$fh>) {
    if (/^Pages:\s+(\d+)/xsm) {
      $pages = $1;
      last;
    }
  }

  close $fh;

  return $pages;
}

########################################################################
sub _cvt2png {
########################################################################
  my %options = @_;

  my $page = sprintf '[%d]', defined $options{page} ? $options{page} - 1 : 0;

  my @args = (
    $options{config}->{helpers}->{convert}, $options{infile} . $page,
    '-auto-orient',                         '-thumbnail',
    $options{size} . '>',                   '-gravity',
    'center',                               '-crop',
    $options{size} . '+0+0!',               '-background',
    'transparent',                          '-flatten',
    $options{target},
  );

  $LOGGER->debug( Dumper( [ args => \@args ] ) );

  return system @args;
}

########################################################################
sub create_preview {
########################################################################
  my %options = @_;

  my ( $w, $h ) = split /x/xsm, $options{size};

  my ( $name, $path, $ext ) = fileparse( $options{infile}, qr/[.][^.]*/xsm );
  $name ||= $ext;

  $options{target} = sprintf '%s%s-%s.png', $path, $name, $w;

  _cvt2png(%options);

  if ( !-s $options{target} ) {
    my ( undef, $tempfile ) = tempfile;

    my $cmd = sprintf '%s -f 1 -l 1 %s %s', $options{config}->{helpers}->{pdftops}, $options{infile}, $tempfile;

    `$cmd`;

    if ( -s $tempfile ) {
      $options{infile} = $tempfile;
      _cvt2png(%options);
    }

    if ( $tempfile && -s $tempfile ) {
      unlink $tempfile;
    }
  }

  return ( -s $options{target} ) ? $options{target} : ();
}

########################################################################
sub fatal_error {
########################################################################
  my ($err) = @_;

  $LOGGER->error("fatal error: $err");

  print <<"END_OF_TEXT";
Content-Type: text/plain
Status: 500

$err
END_OF_TEXT

  exit 1;
}

########################################################################
sub fetch_config {
########################################################################

  my ($name) = fileparse( $PROGRAM_NAME, qr/[.][^.]*$/xsm );

  local $RS = undef;

  my $dist_dir = dist_dir('DocConverter');

  my $file = sprintf '%s/.cfg', $name;

  open my $fh, '<', $file
    or die "could not open config file [$file]";

  my $config = eval { return from_json(<$fh>); };

  close $fh;

  if ( !$config || $EVAL_ERROR ) {
    fatal_error($EVAL_ERROR);
  }

  return $config;
}

########################################################################
sub send_result {
########################################################################
  my ( $status, $result ) = @_;

  print <<"END_OF_TEXT";
Content-Type: application/json
Status: $status

END_OF_TEXT

  print ref $result ? to_json( $result, { pretty => $TRUE } ) : $result;

  return;
}

########################################################################
sub get_status {
########################################################################
  my ($args) = @_;

  my $result;

  $LOGGER->( sprintf 'document-id: %s pid: %s bucket: %s', @{$args}{qw/document-id pid bucket/} );

  my $bucket = $args->{s3}->bucket( $args->{bucket} );

  # find the lastest status file
  if ( !$args->{pid} ) {
    my $list = $bucket->list( { prefix => $args->{'document-id'} } );

    $LOGGER->debug( Dumper $list);

    my $newest;
    my $pid;

    foreach ( @{ $list->{keys} } ) {
      if ( $_->{key} =~ /\/(\d+)\-status[.]json$/xsm ) {
        my $status_date = Date::Manip::Date->new( $_->{last_modified} );

        if ( !$newest ) {
          $pid    = $1;
          $newest = $status_date;
        }
        elsif ( $newest->cmp($status_date) < 0 ) {
          $pid    = $1;
          $newest = $status_date;
        }
      }
    }

    if ($pid) {
      $args->{pid} = $pid;
    }

    $LOGGER->info( $pid . ' is the newest' );
  }

  my $status_file = get_from_s3( $bucket, $args->{'document-id'}, sprintf '%s-status.json', $args->{pid} );

  if ( $status_file && -s $status_file ) {
    local $RS = undef;

    open my $fh, '<', $status_file
      or croak 'could not open ' . $status_file;

    $result = <$fh>;

    close $fh;
  }

  return $result;
}

########################################################################
sub convert_document {
########################################################################
  my ($args) = @_;

  my $pid = fork;

  if ($pid) {
    my $result = {
      pid => $pid,
      url => sprintf( 'http://%s/converter/%s/%s/%s', $ENV{HTTP_HOST}, @{$args}{qw/bucket document-id/}, $pid ),
    };

    return $result;
  }

  close STDOUT;
  close STDIN;

  my $t0 = [gettimeofday];
  my $t1 = $t0;
  my $t  = {};

  my $document_id     = $args->{'document-id'};
  my $file_to_convert = $args->{file};
  my $config          = $args->{config};

  my $bucket = $args->{s3}->bucket( $args->{bucket} );

  # retrieve document from cloud
  my $infile = get_from_s3( $bucket, $document_id, $file_to_convert );

  my $result;

  if ( !$infile || -s $infile ) {
    $result->{error} = $args->{s3}->errstr;
  }

  $t->{s3_time} = tv_interval( $t1, [gettimeofday] );
  $t1 = [gettimeofday];

  my ( $name, undef, $ext ) = fileparse( $file_to_convert, qr/[.][^.]*/xsm );
  $name ||= $ext;  # ex: .emacs

  my ( undef, $path ) = fileparse( $infile, qr/[.][^.]*/xsm );
  my $outfile = sprintf '%s%s.pdf', $path, $name;

  $LOGGER->info("outfile: $outfile");
  $LOGGER->info("infile: $infile");

  $result = {
    'document-id' => $args->{'document-id'},
    pid           => $PID
  };

  if ( $args->{pdf} && $infile && -s $infile ) {
    # create PDF
    my $cmd = sprintf '%s %s %s', $config->{helpers}->{doc2pdf}, $infile, $outfile;

    $LOGGER->info( 'command: ' . $cmd );
    $LOGGER->info(`$cmd 2>/dev/null`);

    if ( -s $outfile ) {
      $result->{pdf_size} = -s "$outfile";
      $result->{pdf}      = {
        name  => "$name.pdf",
        pages => pdfinfo( $outfile, $config ),
        s3    => sprintf 's3://%s/%s/%s.pdf',
        @{$args}{qw/bucket document-id/}, $name
      };
    }

    $t->{libreoffice_time} = tv_interval( $t1, [gettimeofday] );
    $t1 = [gettimeofday];

    put_to_s3( $bucket, $document_id, $outfile );
    $t->{s3_time} += tv_interval( $t1, [gettimeofday] );
    $t1 = [gettimeofday];
  }

  if ( -s $outfile && $args->{thumb} && @{ $args->{thumb} } ) {
    # create thumbs
    my @thumbs;
    foreach ( @{ $args->{thumb} } ) {
      push @thumbs, create_preview( config => $config, size => $_, infile => $outfile );
    }

    $t->{imagemagick_time} = tv_interval( $t1, [gettimeofday] );
    $t1 = [gettimeofday];
    $LOGGER->info( Dumper( [ thumbs => \@thumbs ] ) );

    $result->{thumbs} = [];

    foreach (@thumbs) {
      my ( $name, $path, $ext ) = fileparse( $_, qr/[.][^.]*$/xsm );

      push @{ $result->{thumbs} },
        {
        name => "$name$ext",
        size => -s $_,
        s3   => sprintf 's3://%s/%s/%s%s',
        @{$args}{qw(bucket document-id)}, $name, $ext
        };

      put_to_s3( $bucket, $document_id, $_ );
    }

    $t->{s3_time} += tv_interval( $t1, [gettimeofday] );
    $t1 = [gettimeofday];
  }

  $t->{elapsed_time} = tv_interval( $t0, [gettimeofday] );

  # write status file
  my $dir = tempdir( CLEANUP => $TRUE );

  my $status_file = sprintf '%s/%s-status.json', $dir, $PID;

  $result->{conversion_time} = $t;

  open my $fh, '>', $status_file
    or croak 'could not open ' . $status_file . ' for writing';

  print {$fh} to_json( $result, { pretty => $TRUE } );

  close $fh;

  put_to_s3( $bucket, $document_id, $status_file );

  return;
}

########################################################################
sub main {
########################################################################

  my $config = fetch_config();

  my $args = eval {

    my $config = fetch_config();

    return {
      config => $config,
      s3     => Amazon::S3->new( credentials => Amazon::Credentials->new )
    };
  };

  if ($EVAL_ERROR) {
    fatal_error($EVAL_ERROR);
  }

  init_logger( $ENV{LogLevel} // $config->{log_level} // 'info' );

  $LOGGER->info("--- Starting $PROGRAM_NAME ---");
  $LOGGER->info( 'REQUEST_METHOD: %s', $ENV{REQUEST_METHOD} );

  my $uri    = $ENV{PATH_INFO};
  my $method = $ENV{REQUEST_METHOD};

  if ( $method eq 'POST' ) {
    # read parameters from STDIN
    my $parms = eval {
      local $RS = undef;

      from_json(<>);
    };

    if ($EVAL_ERROR) {
      fatal_error($EVAL_ERROR);
    }

    map { $args->{$_} = $parms->{$_} } keys %{$parms};

    # support different forms (parameters sent as JSON?)
    #
    #   /converter/bucket/document-id/file
    #   /converter/document-id/file
    #   /converter/file

    if ( $uri
      =~ /converter\/(.*?)\/([0-9A-F]{8}\-[0-9A-F]{4}\-[0-9A-F]{4}\-[0-9A-F]{4}\-[0-9A-F]{12})\/([^\/]*)$/xsm )
    {
      $args->{bucket}        = $1;
      $args->{'document-id'} = $2;
      $args->{file}          = $3;
    }
    elsif (
      $uri =~ /converter\/([0-9A-F]{8}\-[0-9A-F]{4}\-[0-9A-F]{4}\-[0-9A-F]{4}\-[0-9A-F]{12})\/([^\/]*)$/xsm ) {
      $args->{'document-id'} = $1;
      $args->{file}          = $2;
    }
    elsif ( $uri =~ /converter\/([^\/]*)$/xsm ) {
      $args->{file} = $1;
    }
    elsif ( $uri =~ /converter\/?/xsm ) {
    }

    if ( $args->{bucket} && $args->{'document-id'} && $args->{file} ) {
      my $result = convert_document($args);

      if ($result) {
        send_result( $HTTP_OK, $result );
      }
    }
    else {
      fatal_error('error: no bucket, document-id, or file');
    }
  }
  elsif ( $method eq 'GET' ) {
    use CGI;

    my $cgi = CGI->new;

    map { $args->{$_} = $cgi->param($_) } ( $cgi->param );

    # support CGI variables
    #
    #   /converter/bucket/document-id/pid
    #   /converter/document-id?pid=&bucket=&
    #   /converter/document-id/pid?bucket=
    #   /converter?document-id=&bucket=&pid=
    #   /converter/pid?document-id&bucket=

    if ( $uri
      =~ /converter\/(.*?)\/([0-9A-F]{8}\-[0-9A-F]{4}\-[0-9A-F]{4}\-[0-9A-F]{4}\-[0-9A-F]{12})(\/\d+|\/)?$/xsm )
    {
      $args->{bucket}        = $1;
      $args->{'document-id'} = $2;
      if ($3) {
        ( undef, $args->{pid} ) = split /\//xsm, $3;
      }
    }
    elsif (
      $uri =~ /converter\/([0-9A-F]{8}\-[0-9A-F]{4}\-[0-9A-F]{4}\-[0-9A-F]{4}\-[0-9A-F]{12})(\/\d+)?$/xsm ) {
      $args->{'document-id'} = $1;
      if ($2) {
        ( undef, $args->{pid} ) = split /\//xsm, $2;
      }
    }
    elsif ( $uri =~ /converter\/([0-9A-F]{8}\-[0-9A-F]{4}\-[0-9A-F]{4}\-[0-9A-F]{4}\-[0-9A-F]{12})\/?$/xsm ) {
      $args->{'document-id'} = $1;
    }
    elsif ( $uri =~ /converter\/\d+$/xsm ) {
      $args->{pid} = $1;
    }

    if ( $args->{bucket} && $args->{'document-id'} ) {
      # try to get process process status. it's either:
      #  a. done
      #  b. still running
      #  c. it died and never left a status file
      my $status = get_status($args);

      if ($status) {
        send_result( $HTTP_OK, $status );
      }
      elsif ( kill 0, $args->{pid} ) {
        send_result( $HTTP_NOT_FOUND, { status => $HTTP_NOT_FOUND, message => 'running' } );
      }
      else {
        send_result( $HTTP_SERVER_ERROR, { status => $HTTP_SERVER_ERROR, message => 'process not running' } );
      }
    }
    else {
      fatal_error("error: no bucket or document-id");
    }
  }
  else {
    fatal_error("error: invalid request");
  }

  return 0;
}

exit main();

__END__

1;


=pod

=head1 NAME

 doc-converter.cgi

=head1 SYNOPSIS

 $ echo '{ "pdf": "1", "thumb" : "70x90"}' | \
 curl -H 'Content-Type: plain/text' \
      -X PUT \
      --data-binary @- http://10.0.1.198/converter/mybucket/F4B6368A-8176-11E5-9C30-59359020DED9/foo.xlsx

=head1 DESCRIPTION

Implements a document conversion service that converts .xls[x],
.doc[x], .png, .jpg files to PDF.  Additionally creates thumbnail
images.

See `man doc2pdf-client` for details.

=head1 USAGE

The C<doc-converter> service will accept POST and GET requests in various forms.

=head2 POST

C<POST> requests are made when requesting a conversion.  The request
URI may take serveral forms depending on what additional information
is provided as part of a JSON payload.

=head3 URI Forms

=over 5

=item /converter/bucket-name/document-id/filename

=item /converter/document-id/filename

=item /converter/filename

=item /converter

=back

=head3 JSON Payload

=over 5

=item pdf

B<Boolean:> 0 or 1, indictes if the service should create a PDF

=item thumb

B<Array:> one or more thumbnail size specifiers of the form 'wxh'.

Example:

  [ '70x90', '400x600' ]

=item file

B<String>: name of the file to convert.

=item bucket

B<String:> name of the S3 bucket where the file will be found and
where the PDF or thumbnails will be created.

=item page

The page number from which to create the thumbnails.  The default is
1, the first page.

=item document-id

B<String>: the GUID document identifier of the form:

 [0-9A-F]{8}\-[0-9A-F]{4}\-[0-9A-F]{4}\-[0-9A-F]{4}\-[0-9A-F]{12}

A good source of GUIDs is the module C<Data::UUID>.

=back

=head2 GET

A C<GET> request is used to retrieve the status of the
conversion. Again, a C<GET> request can take on different forms
described below.

=over 5

=item /converter/bucket/document-id/pid

=item /converter/bucket/document-id

=item /converter?bucket=bucket-name&document-id=?&pid=?

You can use CGI style options. The C<pid> value is optional. If it is
ommitted, then the status of the last successful conversion is
returned.

=back

=head1 FAQ

=head2 How do I call this service?

The project includes a reference client (C<doc2pdf-client>), although
you should consider using your own tools and techniques before
deciding to use the reference client. You can do anything from using
the AWS CLI tools to using C<curl>.

=over 5

=item Send a document and request a conversion

 $ aws s3 cp foo.xlsx s3://mybucket/F4B6368A-8176-11E5-9C30-59359020DED9/

 $ echo '{ "pdf": "1", "thumb" : "70x90"}' | \
 curl -H 'Content-Type: plain/text' \
      -X PUT \
      --data-binary @- http://10.0.1.198/converter/mybucket/F4B6368A-8176-11E5-9C30-59359020DED9/foo.xlsx

=item Get the status of a conversion

 $ curl http://10.0.1.198/converter/mybucket/F4B6368A-8176-11E5-9C30-59359020DED9/

=back

=head2 What kind of conversion are possible?

The service is designed primarily to convert Office type documents
(.doc[x], .xls[x]) to PDFs.  Since the service uses the LibreOffice
and ImageMagick programs, you can actually convert other formats as
well.  Additionally, the service will convert .png or .jpg files to
PDFs and create .png thumbnails from your files.

=over 5

=item .doc[x], .odt

Microsoft Word or OpenOffice documents.

=item .xls[x], .ods

Microsoft Excel, OpenOffice spreadsheets.

=item .png, .jpg

Graphic files are converted using ImageMagick

=back


=head2 How do I send the document to the service?

You donE<039>nt. The service relies on the document residing in an S3
bucket in which both the client and the service have adequate
permissions.  Use the methods at your disposal to send your document
to the S3 bucket you are using for conversions.

=head2 How do I retrieve a document or thumbnail?

The purpose of the conversion service is to convert documents in place
in AmazonE<039>s S3 service.  Presumably, you knew that and you have a
way to put and get objects from S3.

=head2 Is there are way to speed up conversion?

Maybe. You might want to use more powerful EC2 instances.  In limited
testing of this, I have found empirically that there is not much
difference in conversion time between a C<t2.micro> and a C<t2.small>.
By that I mean, individual runs of a conversion do not seem to be
faster on a C<t2.small>, indicating that memory alone is not a factor.
Faster CPUs may yield better results, however you will most likely be
throughput bound (number of conversions/second) anyway unless you
create multiple instances of the conversion service and place them
behind a load balancer.  This is due to the fact that the LibreOffice
conversion process seems to be single threaded.

Moreover, the C<bash> script (C<doc2pdf>) that invokes the LibreOffice
headless instance itself enforces the single conversion at-a-time
model to create a stable converter.  Experiments attempting to execute
multiple instances of LibreOffice on the same server have not been
totally successful.

LibreOffice theoretically supports a server mode that accepts
connections on a TCP port which would, theoretically, reduce the
LibreOffice startup time at least.  Again, this has been a source of
frustration when actually trying to use LibreOffice in that mode as it
relies on a Python/Uno interface that I at least have not grokked
fully. YMMV.

For the intrepid, I<pyuno> explorer who wants to give this a go, you
should not have too difficult a time in replacing my interface to
LibreOffice.  The difficulty seems to be a disconnect between the
version of Python you may be running on your O/S and the version of
Python that was used to create the pyuno LibreOffice interface.  You
have been warned.

ThereE<039>s also the Java route which appears equally less
trodden. Something called the I<JOD converter> was written years ago
but has gone into hibernation.  The last commit on GitHub was 2012.

 L<https://github.com/mirkonasato/jodconverter?

=head2 Where can I get more information?

See `man doc2pdf-client` for more details.

=head1 AUTHOR

Rob Lauer - <rlauer6@comcast.net>

=head1 LICENSE

GNU General Public License v3.0

Copyright (C) 2015, Robert C. Lauer

=cut
