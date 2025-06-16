#/usr/bin/env perl

# Read LibreOffice xml configuration file and set the OOXMLRecalcMode
# flag to "1"
#
# Copyright (C) 2025 TBC Development Group, LLC
# All right reserved.
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

use XML::Twig;
use Getopt::Long;
use File::Temp qw(tempfile);
use English qw(-no_match_vars);
use Data::Dumper;

# create a temp file to hold new .xml file that we created
my ( $fh, $filename ) = tempfile( SUFFIX => '.xml' );

exit main();

# set recalculate formulas on load value to "Recalc always"
########################################################################
sub set_OOXMLRecalcMode {
########################################################################
  my ( $t, $prop ) = @_;

  if ( $prop->{'att'}->{'oor:name'} eq 'OOXMLRecalcMode' ) {
    $prop->first_child('value')->set_text("0");

    $prop->flush($fh);
  }

  return;
}

########################################################################
sub main {
########################################################################

  my $infile;
  my $pretty;

  GetOptions( 'infile=s', \$infile, 'pretty', \$pretty );

  if ( !$infile ) {
    print "usage: $PROGRAM_NAME -i config-file [--pretty]\n";
    exit 1;
  }

  die "file [$infile] not found\n"
    if !-s $infile;

  # I empircally determined that the property to set would be found on this path...
  my $t = XML::Twig->new(
    twig_handlers => { 'oor:component-schema/component/group/group/prop' => \&set_OOXMLRecalcMode },
    pretty_print  => $pretty ? 'indented' : 'none',
    keep_encoding => 1
  );

  $t->parsefile($infile);
  $t->flush($fh);

  # save old file, and replace with the new file
  die "error: could not create output file.\n"
    if !-s $filename;

  rename $infile,   "$infile.sav";
  rename $filename, $infile;

  return 0;
}

1;

__END__

=pod

=head1 NAME

fix-OOXMLRecalcMode.pl

=head1 SYNOPSIS

 fix-OOXMLRecalcMode.pl -i /opt/libreoffice4.3/share/registry/main.xcd -p

=head1 DESCRIPTION

Sets LibreOfficeE<039>s OOXMLRecalcMode to "0".

=head1 NOTES

After an exhaustive night of trying to figure out why LibreOffice was
not recalculating my formulas in an XLSX file prior to converting it
to a PDF, I discovered that LO had changed the I<recalculate formulas
on load> setting for OOXML documents I< for some reason>.

After a little bit more hunting I discovered that it was possible to
reset that flag in LOE<039>s configuration file
(F</opt/libreoffice4.3/share/registry/main.xcd>).  Keep in mind the
path to this file may change with versions and where LO happens to be
currently installed.

Way down in this XML document we find a property B<OOXMLRecalcMode>
which, suprisingly, should be set to "0".  The value it turns out
after GMAO (Googling My Ass Off), is not a boolean, but rather an
index into an enumerated list.  I found this nugget of info in
someoneE<039>s GitHub repository:

  <group oor:name="Load">
    <info>
      <desc>Contains settings that affect formula handling while loading.</desc>
    </info>
    <prop oor:name="OOXMLRecalcMode" oor:type="xs:int" oor:nillable="false">
  <!-- UIHint: Tools - Options - Spreadsheet - Formula -->
      <info>
        <desc>Specifies whether to force a hard recalc after load on OOXML-based Excel documents (2007 and newer).</desc>
      </info>
      <constraints>
        <enumeration oor:value="0">
          <info>
            <desc>Recalc always</desc>
          </info>
        </enumeration>
        <enumeration oor:value="1">
          <info>
            <desc>Recalc never</desc>
          </info>
        </enumeration>
        <enumeration oor:value="2">
          <info>
            <desc>Ask before Recalc</desc>
          </info>
        </enumeration>
      </constraints>
      <value>1</value>
    </prop>
   ....
  </group>


=head1 AUTHOR

Rob Lauer - <rlauer6@comcast.net>

=head1 SEE OTHER

L<XML::Twig>

=head1 LICENSE

GNU General Public License v3.0

Copyright (C) 2025, TBC Development Group, LLC
All rights reserved

=cut
