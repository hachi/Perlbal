#!/usr/bin/perl

use strict;
use Perlbal::Test;
use Test::More 'no_plan';

my $msock = start_server("");
ok($msock);

1;
