#!/usr/bin/perl -w

use strict;
use File::Find;
use Test::More tests => 16;

my $modfind = sub { return unless my ($mod) = $File::Find::name =~ /(Perlbal.*)\.pm/; $mod =~ s|/|::|g; use_ok($mod) };
find($modfind, "lib/");
