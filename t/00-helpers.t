#!/usr/bin/env perl
use strict;
use warnings;

use Data::Dumper;
use English qw(no_match_vars);

package Test::Helpers;

use Role::Tiny::With;
with 'DocConverter::Role::Helpers';

use parent qw(Class::Accessor::Fast);

__PACKAGE__->follow_best_practice;
__PACKAGE__->mk_accessors(qw(log_level logger));

package main;

use Carp;
use Carp::Always;
use Log::Log4perl qw(:easy);
use Log::Log4perl::Level;

use Test::More;

Log::Log4perl->easy_init($INFO);
my $helper = Test::Helpers->new( { logger => Log::Log4perl->get_logger } );

my $pages = $helper->pdfinfo('test.pdf');

ok( $pages, 'pdfinfo returns number of pages' );
diag($pages);

done_testing;

1;
