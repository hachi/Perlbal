#!/usr/bin/perl

use strict;
use Perlbal::Test;
use Test::More 'no_plan';

my $msock = Perlbal::Test::start_server("");
ok($msock);

1;
