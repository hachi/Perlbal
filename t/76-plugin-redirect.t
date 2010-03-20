#!/usr/bin/perl

use strict;
use Perlbal::Test;
use Perlbal::Test::WebServer;
use Perlbal::Test::WebClient;
use Test::More 'no_plan';

my $port = new_port();

my $conf = qq{
LOAD Redirect
LOAD Vhosts

CREATE SERVICE ss
    SET role = selector
    SET listen = 127.0.0.1:$port
    SET persist_client = 1
    SET plugins = Vhosts
    VHOST example.com = test
ENABLE ss

CREATE SERVICE test
    SET role = web_server
    SET persist_client = 1
    SET plugins = Redirect
    REDIRECT HOST example.com example.net
ENABLE test
};

my $msock = start_server($conf);
ok($msock, 'perlbal started');

# make first web client
my $wc = Perlbal::Test::WebClient->new;
$wc->server("127.0.0.1:$port");
$wc->keepalive(1);
$wc->http_version('1.0');

my $resp = $wc->request({ host => "example.com", }, "foo/bar.txt"); # Test lib prepends '/' for me.
ok($resp, "Got a response");

is($resp->code, 301, "Redirect has proper code");
like($resp->header("Location"), qr{^http://example.net/foo/bar.txt$}, "Correct redirect response");
like($resp->header("Connection"), qr/Keep-Alive/i, "... and keep-alives are on");

1;
