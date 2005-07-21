#!/usr/bin/perl

use strict;
use Perlbal::Test;

use Perlbal;

use Test::More 'no_plan';

my @plugins = qw(Highpri Palimg Queues Stats Vhosts);

foreach my $plugin (@plugins) {
    ok(eval("use Perlbal::Plugin::$plugin; 1;"), "plugin compiled - $plugin");
}
