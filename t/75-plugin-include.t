#!/usr/bin/perl

use strict;
use Perlbal::Test;

use Test::More tests => 8;
require HTTP::Request;
require HTTP::Date;

my $dir = tempdir();

my $msock = start_server();
ok($msock, "manage sock");

ok(manage("LOAD Include"), "load include");

# Build conf files
for ('a' .. 'c') {
    my $port = new_port();

    my $conf = qq{
CREATE SERVICE test_$_
SET test_$_.role = web_server
SET test_$_.listen = 127.0.0.1:$port
SET test_$_.docroot = $dir
SET test_$_.dirindexing = 0
SET test_$_.persist_client = 1
ENABLE test_$_
};

    open(F, ">$dir/$_.conf") or die "Couldn't open $dir/$_.conf: $!\n";
    print F $conf;
    close F;
}

ok(manage("INCLUDE = $dir/a.conf"), "include single");

ok(manage("INCLUDE = $dir/b* $dir/c*"), "include multi");

ok(! manage("INCLUDE = $dir/d.conf"), "error on nonexistent conf");

my $s_output = manage_multi("show SERVICE");

for ('a' .. 'c') {
    like($s_output, qr/^test_$_ .+ ENABLED/m, "test_$_ loaded");
}

1;
