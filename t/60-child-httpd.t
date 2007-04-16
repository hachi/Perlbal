#!/usr/bin/perl

use strict;
use Perlbal::Test;
use Perlbal::Test::WebServer;
use Perlbal::Test::WebClient;
use Test::More;
use FindBin qw($Bin);

unless ($ENV{PERLBAL_TEST_ALPHA}) {
    plan skip_all => 'Alpha feature; test skipped without $ENV{PERLBAL_TEST_ALPHA}';
    exit 0;
} else {
    plan tests => 4;
}

# setup a simple perlbal that uses the above server
my $pb_port = new_port();
my $conf = qq{

CREATE SERVICE test
  SET test.role = reverse_proxy
  SET test.listen = 127.0.0.1:$pb_port
  SET test.persist_client = 1
  SET test.persist_backend = 1
  SET test.connect_ahead = 0
  SET test.server_process = $Bin/helper/child-httpd.pl
ENABLE test

};

my $msock = start_server($conf);
ok($msock, 'perlbal started');

# make first web client
my $wc = Perlbal::Test::WebClient->new;
$wc->server("127.0.0.1:$pb_port");
$wc->keepalive(0);
$wc->http_version('1.0');
ok($wc, 'web client object created');

# see if a single request works
my $resp = $wc->request('status');
ok($resp, 'status response ok');
like($resp->content, qr/and I am pid=/, "got response from child process");


1;
