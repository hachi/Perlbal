#!/usr/bin/perl

use strict;
use Perlbal::Test;

use File::Temp qw/tempdir/;
use Test::More 'no_plan';

my $port = 60001;
my $dir = tempdir( CLEANUP => 1 );

my $conf = qq{
CREATE SERVICE test
SET test.role = web_server
SET test.listen = 127.0.0.1:$port
SET test.docroot = $dir
SET test.dirindexing = 0
SET test.enable_put = 1
SET test.enable_delete = 1
SET test.min_put_directory = 1
SET test.persist_client = 1
ENABLE test
};

my $msock = Perlbal::Test::start_server($conf);

ok($msock);


1;
