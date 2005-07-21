#!/usr/bin/perl

use strict;
use Perlbal::Test;

use Perlbal;

use Test::More tests => 5;

my @plugins = qw(Highpri Palimg Queues Stats Vhosts);

foreach my $plugin (@plugins) {
    require_ok("Perlbal::Plugin::$plugin");
}
