#!/usr/bin/env perl

# Document converter client - converts .xls[x], .doc[x] to .pdf

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

use Amazon::Credentials;
use Carp;
use DocConverter::Utils;
use DocConverter::Constants;
use Data::Dumper;
use Data::UUID;
use English qw(-no_match_vars);
use File::Basename;
use File::Temp qw/tempdir tempfile/;
use Getopt::Long qw(:config no_ignore_case);
use HTTP::Request;
use JSON;
use LWP::UserAgent;
use Log::Log4perl qw(:easy);
use Log::Log4perl::Level;

########################################################################
sub usage {
########################################################################
  print {*STDOUT} <<"EOM";
Usage: $PROGRAM_NAME [options] file1 file2 ...

Converts .doc[x], .xls[x], .png, .jpg, or .txt files to PDF using a
remote document converter service.

 -b, --bucket                   Amazon S3 bucket to fill
 -d, --debug                    simulate conversion
 -D, --document-id              key prefix in bucket of file
 -h, --help                     usage
 -H, --host                     host name of service (default: localhost)
 -k, --key                      key in bucket (document-id/file-name)
 -K, --aws-access-key-id        AWS access key id
 -m, --mime-type                MIME type of the input stream
 -n, --name                     Name for the input stream or the name of an existing file to convert
 -p, --pdf                      create a pdf (default), use --nopdf if you don't want one
 -P, --page                     use page N as the page for thumbs, defaults to page 1
 -s, --sleep                    time in seconds to sleep between status checks (default: 1s)
 -S, --aws-secret-key           AWS secret key
 -t, --timeout                  timeout in seconds
 -T, --thumbs                   on or more strings (hxw,hxw,...) representing thumbnail sizes,

Example: doc2pdf-client -b mybucket foo.xlsx

EOM

  exit 1;
}

########################################################################
sub get_status {
########################################################################
  my %options = @_;

  my ( $protocol, $host, $bucket, $document_id ) = @options{qw(protocol host bucket document-id)};

  my $url = $options{url} // sprintf '%s://%s/converter/%s/%s', $protocol, $host, $bucket, $document_id;

  if ( $options{pid} ) {
    $url .= $SLASH . $options{pid};
  }

  my $req = HTTP::Request->new( GET => $url );

  my $ua = LWP::UserAgent->new;

  my $rsp = $ua->request($req);

  $LOGGER->debug( Dumper( [ req => $req, rsp => $rsp ] ) );

  my $result = eval {
    if ( $rsp->is_success ) {
      return from_json( $rsp->content );
    }
  };

  return $result;
}

########################################################################
sub convert_document {
########################################################################
  my %options = @_;

  my $ua = LWP::UserAgent->new;

  my ( $protocol, $host, $bucket, $document_id, $name ) = @options{qw(protocol host bucket document-id name)};

  my $url = sprintf '%s://%s/converter/%s/%s/%s', $protocol, $host, $bucket, $document_id, $name;

  my @headers = (
    'Content-Type'       => 'application/json',
    'x-doc-converter-id' => $document_id,
  );

  my $req = HTTP::Request->new( POST => $url, \@headers, to_json( \%options ) );

  my $rsp = $ua->request($req);

  $LOGGER->debug( Dumper( [ rsp => $rsp ] ) );

  my $result;

  if ( $rsp->is_success ) {
    $result = eval { return from_json( $rsp->content ); };

    $LOGGER->debug( Dumper( [ result => $result ] ) );

    if ($EVAL_ERROR) {
      carp "invalid return result from server [$EVAL_ERROR]\n";
      return;
    }

    # -T 0 means we just want to submit the document for conversion
    return $result
      if !$options{timeout};

    $url = $result->{url};
    $req = HTTP::Request->new( GET => $url );

    my $maxtries = $options{timeout} / $options{sleep};

    while ( $maxtries-- > 0 ) {
      $rsp = $ua->request($req);

      $LOGGER->debug( Dumper( [ rsp => $rsp ] ) );

      last if $rsp->is_success || $rsp->code ne $HTTP_NOT_FOUND;

      sleep $options{sleep};
    }

    if ( $rsp->is_success ) {
      $result = eval { from_json( $rsp->content ); };
    }

    if ($EVAL_ERROR) {
      carp "error parsing result: [$EVAL_ERROR]\n";
      return;
    }
  }

  if ( !$rsp->is_success ) {
    carp sprintf "unexpected response from server (%s): %s\n", $rsp->code, $rsp->content;
    return;
  }

  return $result;
}

########################################################################
sub main {
########################################################################

  my @option_specs = qw(
    bucket=s
    debug
    document-id|D=s
    help|h
    host|H=s
    key=s
    mime-type=s
    name=s
    page|P=i
    pdf!
    protocol=s
    sleep=i
    thumb=s@
    timeout|T=s
    url=s
    log-level|l=s
  );

  # defaults
  my %options = (
    pdf         => $TRUE,
    protocol    => 'http',
    host        => $ENV{DOC_CONVERTER_HOST}    || 'localhost',
    timeout     => $ENV{DOC_CONVERTER_TIMEOUT} || $DEFAULT_TIMEOUT,
    bucket      => $ENV{DOC_CONVERTER_BUCKET},
    sleep       => $DEFAULT_SLEEP_INTERVAL,
    page        => 1,
    'log-level' => 'info',
  );

  GetOptions( \%options, @option_specs )
    or usage();

  if ( $options{key} ) {
    if ( $options{key} =~ /([0-9A-F]{8}\-[0-9A-F]{4}\-[0-9A-F]{4}\-[0-9A-F]{4}\-[0-9A-F]{12})\/([^\/]*)$/xsm ) {
      $options{'document-id'} = $1;
      $options{name}          = $2;
    }
  }

  init_logger( $options{log_level} );

  $LOGGER->debug( Dumper( [ options => \%options ] ) );

  my $credentials = Amazon::Credentials->new;
  $options{credentials} = $credentials;

  foreach (qw(bucket host)) {
    next if $options{$_};
    croak "ERROR: $_ is a required option\n";
  }

  # just get status, no filename to convert
  if ( !@ARGV ) {

    croak "ERROR: no file to convert and no document-id to status\n"
      if !exists $options{'document-id'};

    my $status = get_status(%options);

    if ($status) {
      print {*STDOUT} to_json( $status, { pretty => $TRUE } );
    }

    exit 0;
  }

  # if we're reading from STDIN, we need a filename
  if ( $ARGV[0] eq $DASH ) {
    croak "filename required (use --name)\n"
      if !$options{name};

    my ( $name, undef, $ext ) = fileparse( $options{name}, qr/[.][^.]*$/xsm );

    my $mime_type = $options{'mime-type'};

    croak "mime-type or file extension required (use --mime-type)\n"
      if !$mime_type && !$ext;

    $options{name} = sprintf '%s%s', $name, $mime_type ? $DocConverter::Utils::MIME_TYPES{$mime_type} : $ext;
  }

  my $s3 = eval {
    Amazon::S3->new(
      { aws_secret_access_key => $options{aws_secret_access_key},
        aws_access_key_id     => $options{aws_access_key_id},
        exists $options{token} ? ( 'token', $options{token} ) : ()
      }
    );
  };

  my $bucket = $s3->bucket( $options{bucket} );

  my @files_to_convert = @ARGV;

  my $tmpfile;

  my %names;

  # might be able to stream file to S3?
  if ( !@files_to_convert && $files_to_convert[0] ne $DASH ) {
    my $fh;
    ( $fh, $tmpfile ) = tempfile;
    $files_to_convert[0] = $tmpfile;

    binmode STDIN
      or croak "cannot binmode STDIN\n";

    my $bufsize = $BUFFER_SIZE * 4;
    my $buf;

    while ( read STDIN, $buf, $bufsize ) {
      print {$fh} $buf;
    }

    close $fh;

    $names{$tmpfile} = $options{name};
  }

  my @details;

  # if we have files to convert, then we need to send them and convert
  # them, otherwise we just have to tell the service to convert the
  # file.
  if (@files_to_convert) {
    foreach my $file (@files_to_convert) {

      if ( !-s $file ) {
        carp "skipping: $file empty or not found\n";
        next;
      }

      my $document_id;

      if ( !$options{'document-id'} ) {
        my $ug   = Data::UUID->new;
        my $uuid = $ug->create();
        $document_id = $ug->to_string($uuid);
      }
      else {
        $document_id = $options{'document-id'};
      }

      my $rsp = put_to_s3( $bucket, $document_id, $file );

      croak 'ERROR: ' . $s3->errstr()
        if !$rsp;

      $LOGGER->info("sent $document_id/$file to s3");

      my $result = convert_document(
        'document-id' => $document_id,
        file          => $file,
        name          => ( $names{$file} || basename $file),
        %options
      );

      if ($result) {
        $LOGGER->info( to_json( $result, { pretty => $TRUE } ) );
        push @details, $result;
      }
    }

    if ($tmpfile) {
      unlink $tmpfile;
    }
  }
  else {
    if ( $options{name} && $options{'document-id'} ) {

      # if we are converting a PDF, then make sure the --pdf not set
      if ( $options{name} =~ /[.]pdf/xsm ) {
        $options{pdf} = undef;
      }

      if ( $options{thumb} || $options{pdf} ) {
        push @details,
          convert_document(
          'document-id' => $options{'document-id'},
          name          => $options{name},
          %options
          );
      }
      else {
        push @details, get_status(%options);
      }
    }
    else {
      carp "nothing to convert\n";
    }
  }

  print to_json( \@details, { pretty => 1 } ) if @details;

  return 0;
}

1;

__END__

=pod

=head1 NAME

 doc2pdf-client

=head1 SYNOPSIS

 doc2pdf-client --host 10.0.1.198 --bucket mybucket \
                --aws_secret_access_key=your-secret-key --aws_access_key_id=your-key-id foo.xlsx

=head1 DESCRIPTION

Converts .doc[x],.xls[x],.txt,.png, or .jpg files to PDF using a
remote document conversion service based on LibreOfficeE<039>s
I<headless> mode.  Files are sent from the client to an S3 bucket on
which you (and the service) both have read and write permissions.  For
each file sent, a PDF file is created.  Optionally, the conversion
process can create thumbnail previews of specified sizes.

=head1 HOW IT WORKS

The C<doc2pdf-client> utility is part of the C<doc-converter>
service. It is, as the name suggests a client side utility.  The
server does the heavy lefting of converting documents to PDFs using
LibreOffice.  Essentially, the client sends a file to an S3 bucket,
requests that the C<doc-converter> service do some magic and then may
poll the service until the conversion is complete. The client can
proceed to retrieve the PDF from the bucket or leave it there, your
choice...the document serviceE<039>s job is done.

In summary it works like this:

=over 5

=item 1. A file is sent to an S3 bucket

Both the client and the server should have read/write access to some
S3 bucket.  Typically an acceptable way to provide those permissions
to the server is to assign the EC2 instance that is running the
C<doc-converter> service, a role with an attached policy that provides
all of the necessary permissions.  Such a policy might look something
like this:

  {
      "Version": "2012-10-17",
      "Statement": [
          {
              "Sid": "Stmt1446041925000",
              "Effect": "Allow",
              "Action": [
                  "s3:ListAllMyBuckets"
              ],
              "Resource": "arn:aws:s3:::*"
          },
          {
              "Effect": "Allow",
              "Action": [
                  "s3:ListObjects",
                  "s3:GetObject",
                  "s3:PutObject",
                  "s3:DeleteObject",
                  "s3:ListBucket"
              ],
              "Resource": [
                  "arn:aws:s3:::mybucket",
                  "arn:aws:s3:::mybucket/*"
              ]
          }
      ]
  }

In other words, we first allow the listing of all buckets in the S3
account and then we provide specific permissions for a specific
bucket.

A utility for creating an appropriate role and and policy is provided
for you as part of this project.  The role can then be assigned to the
`doc-converter` server during the stack creation phase so that it has
access to the S3 bucket used to store documents.  In this way, you do
not need to provision access credentials for the document conversion
server.

If you have the AWS CLI tools installed and you have sufficient
privileges to do things like provision new servers and create roles
and policies, then you can try this:

Create a bucket:

 $ aws s3 mb s3://mybucket

Add an appropriate role:

 $ doc-converter-add-role -R bucket-writer -B mybucket

Provision the document conversion server:

 $ libreoffice-create-stack -k mykey -R bucket-writer -S subnet-6033e039

Take a look at:

 $ doc-convert-add-role -h

...and

 $ libreoffice-create-stack -h

C<doc2pdf-client> will send one or more files to the bucket for you,
but the client utility can be used to just POST the request or just
GET the status of the conversion.

You can also pipe data to the client which will be sent for
conversion.  In that case you will need to provide some additional
attributes of the file.

=item 2. Submit the request and retrieve a task id

You POST a JSON file that contains options to a URL that includes the
bucket, a document identifier and the filename.  

  http://10.0.1.198/converter/mybucket/FCA577DA-8120-11E5-BB37-95249020DED9/foo.xlsx

The C<doc-converter> client will actually do all that for you,
including creating a unique document identifier. The document
identifier is used as part of the key name when saving the file to the
S3 bucket.  Likewise the converted files (.pdf, .png) will also use
that document identifier in the key name.

The return from the POST will be a JSON object containing a C<pid>
value and the URL for retrieving the status of the conversion. 

 {
  'pid' => '6259',
  'url' => 'http://10.0.1.198/converter/mybucket/FCA577DA-8120-11E5-BB37-95249020DED9/6259'
 }

=item 3. Poll the service until the request is satified

  $ curl http://10.0.1.198/converter/mybucket/FCA577DA-8120-11E5-BB37-95249020DED9/6259

Again, the C<doc2pdf-client> does this this for you.  Assuming the
file is converted properly, the return from the client will be a JSON
object that contains the details of the conversion.

  {
     "pid" : 6259,
     "pdf_size" : 16745,
     "document-id" : "AD6C25DA-8123-11E5-B094-48259020DED9",
     "pdf" : {
        "name" : "foo.pdf",
        "pages" : "2"
     },
     "thumbs" : [
        {
           "name" : "foo-70.png",
           "size" : 2462
        }
     ],
     "conversion_time" : {
        "s3_time" : 0.183339,
        "imagemagick_time" : 0.270089,
        "libreoffice_time" : 1.127361,
        "elapsed_time" : 1.580844
     }
  }

=back

=head1 BUCKETS and DOCUMENT-IDs

As explained previously the client and server should have permissions
to access the S3 bucket.  Using roles and policies is one way to
achieve this.  ItE<039>s a good practice to give your conversion
server just enough rights to do his job and no more, hence the bucket
policy and role approach described previously.

The C<doc-converter> assumes (and requires) that each document use
a GUID prefix or what we term a I<document-id>.  GUIDs as they are
used for the prefix, are unique identifiers composed of hexadecimal
digits. The regex would look something like this:


 [0-9A-F]{8}\-[0-9A-F]{4}\-[0-9A-F]{4}\-[0-9A-F]{4}\-[0-9A-F]{12}

Example:

 FCA577DA-8120-11E5-BB37-95249020DED9

The artifacts created during the conversion process will also use this
GUID as the prefix of the object.  So, if we were converting
F<test.xlx> located in the bucket named C<mybucket> to a PDF and
creating a thumbnail (70x90) using the I<document-id> above, we would
end up with these S3 objects:

 s3://mybucket/FCA577DA-8120-11E5-BB37-95249020DED9/test.xlsx
 s3://mybucket/FCA577DA-8120-11E5-BB37-95249020DED9/test.pdf
 s3://mybucket/FCA577DA-8120-11E5-BB37-95249020DED9/test-70.png
 s3://mybucket/FCA577DA-8120-11E5-BB37-95249020DED9/status-6259.json

=head2 How do I create a GUID?

The reference client, C<doc2pdf-client> does this for you when it sends
the object for conversion, however if you are not using the reference
client and you want to store things in your bucket yourself, there are
other ways to generate a GUID.

In Perl, we use the C<Data::UUID> module.  There are corresponding
UUID modules in Python, Ruby and/or you can use the Linux command line
utility C<uuid>.

 $ document_id=$(uuid -F STR | tr [a-f] [A-F])

=head1 OPTIONS

The C<doc2pdf-client> scripts accepts several options, some of which
are required, one way or another.

=head2 AWS Credentials

Since weE<039>re going to be sending a file to an S3 bucket, you
naturally need to have your AWS account keys handy or your EC2
instance that is storing the document needs to have a role the permits
uploading a document to the bucket.  There are four ways you can
provide your AWS credentials to the client.

=over 5

=item 1. On the command line

=over 5

=item --aws_access_key_id

=item --aws_secret_access_key

=back

=item 2. In environment variables

=over 5

=item AWS_ACCESS_KEY_ID

=item AWS_SECRET_ACCESS_KEY

=back

=item 3. As temporary credentials from the role of your EC2 instance

If the first two methods fail, then the script will attempt to see if
the EC2 instance has been launced with a role, and if so will request
the temporary credentials.  You need to set the role for the instance
PRIOR to launch.  For more information regarding how to use temporary
IAM credentials see:

L<http://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_use_switch-role-ec2.html>

=item 4. In your F<~/.aws/config> or F<~/.aws/credentials> files.

=back

=head2 Thumbnails

If you would like the service to create one or more thumbnail views of
the PDF file, then you can use the C<--thumb> option one or more
times.  The C<--thumb> option takes a string of the form:

 wxh

...representing the width and height of the thumbnail image.  A
C<.png> file is created from the first page (default) of the PDF for
each thumbnail you request and placed in the same bucket as the
PDF. The page image is resized to the size indicated with the aspect
ratio of the page preserved.

Example:

  --thumb 70x90 --thumb 400x600

You can select a different page to create the thumbnail from using the
C<--page> option.

  --page 2 --thumb 70x90

=head2 Host

You must tell the client the host name of the service using the
C<--host>, C<-H> options or by setting the C<DOC_CONVERTER_HOST>
envrionment variable.

Example:

  --host 10.0.1.198

=head2 Reading from STDIN

You can pipe a file to the conversion process, but you need to name
the file using the C<--name> option and provide '-' as the
filename.  The client will attempt to determine the MIME type from the
extension, if the name you provide includes one.  Alternately, you can
specify the MIME type using the C<--mime-type> option.

Example:

 $ cat foo.xlsx | doc2pdf-client --name=my-amazing-spreadsheet.xlsx -

HereE<039>s a list of valid MIME types to use:

 .pdf  => application/pdf
 .jpg  => image/jpeg
 .png  => image/png
 .xls  => application/vnd-ms-excel
 .doc  => application/msword
 .docx => application/vnd.openxmlformats-officeodocument.wordprocessingml.document
 .xlsx => application/vnd.openxmlformats-officeodocument.spreadhseetml.sheet

=head2 Polling and Timeout

By default, the C<doc2pdf-client> script polls the service after
submitting the request until the conversion process has been
completed, an error is encountered, or a timeout occurs. You can use
the C<--timeout> option to set the polling timeout value in seconds.
The default is 60 seconds.  If you want the client to merely submit
the file and the request and you are not interested in determining the
outcome, set the timeout value to 0.

Example:

 --timeout 0

To get the conversion details at a later time you can request the
status as shown below.

Example:

 $ document_id=$(doc2pdf-client -t 0 foo.xlsx | jq .document_id)

 $ doc2pdf-client --key $document_id

=head1 ENVIRONMENT VARIABLES

The C<doc2pdf-client> will use the following environment variables as
substitutes for the command line arguments.

=over 5

=item DOC_CONVERTER_HOST

 --host

=item DOC_CONVERTER_BUCKET

 --bucket

=item DOC_CONVERTER_TIMEOUT

 --timeout

=item AWS_ACCESS_KEY_ID

  --aws_access_key_id

=item AWS_SECRET_ACCESS_KEY

 --aws_secret_access_key

=back

=head1 PERFORMANCE

This process is optimized for stability and architectural flexibility,
not speed.  First, you should know that LibreOffice as a document
conversion utility is relatively slow, especially on EC2 low
performance servers.  I imagine on faster servers, it performs better
and there may in fact be ways to speed up the conversions.

=head1 AUTHOR

Rob Lauer - <rlauer6@comcast.net>

=head1 LICENSE

GNU General Public License v3.0

Copyright (C) 2015, Robert C. Lauer

=cut

