#!/usr/bin/perl
#
# For now we don't support pipelining, so these tests verify we handle it
# properly, notably not poisoning the backend by injecting two when we only
# know of one, and also dealing okay with POSTs with an extra \r\n, which
# happen in the real world, without disconnecting those users thinking
# they're bogus-pipeline-flooding us.
#

use strict;
use Perlbal::Test;
use Perlbal::Test::WebServer;
use Perlbal::Test::WebClient;

use Test::More tests => 12;
require HTTP::Request;

my $port = new_port();
my $dir = tempdir();

# setup a few web servers that we can work with
my $start_servers = 1; # web servers to start
my @web_ports = map { start_webserver() } 1..$start_servers;
@web_ports = grep { $_ > 0 } map { $_ += 0 } @web_ports;
ok(scalar(@web_ports) == $start_servers, 'web servers started');

my $conf = qq{
CREATE POOL a

CREATE SERVICE test
SET test.role = reverse_proxy
SET test.listen = 127.0.0.1:$port
SET test.persist_client = 1
SET test.persist_backend = 1
SET test.pool = a
SET test.connect_ahead = 0
ENABLE test
};

my $http = "http://127.0.0.1:$port";

my $msock = start_server($conf);
ok($msock, "manage sock");
add_all();

my $sock;
my $get_sock = sub {
    return IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port")
        or die "Failed to connect to perlbal";
};

$sock = $get_sock->();
print $sock "POST /sleep:0.2,status HTTP/1.0\r\nContent-Length: 10\r\n\r\nfoo=56789a";
like(scalar <$sock>, qr/200 OK/, "200 OK on post w/ correct len");

$sock = $get_sock->();
print $sock "POST /sleep:0.2,status HTTP/1.0\r\nContent-Length: 10\r\n\r\nfoo=56789a\r\n";
like(scalar <$sock>, qr/200 OK/, "200 OK on post w/ extra rn not in length");

# test that signal sending works
{
    my $gotsig = 0;
    local $SIG{USR1} = sub { $gotsig = 1; };
    $sock = $get_sock->();
    print $sock "GET /kill:$$:USR1,status HTTP/1.0\r\n\r\n";
    like(scalar <$sock>, qr/200 OK/, "single GET okay");
    ok($gotsig, "got signal");
}

# check that somebody can't sneak extra request to backend w/ both \r\n and nothing in between requests
foreach my $sep ("\r\n", "") {
    diag("separator length " . length($sep));
    my $gotsig = 0;
    local $SIG{USR1} = sub { $gotsig = 1; };
    $sock = $get_sock->();
    print $sock "POST /sleep:0.5,status HTTP/1.0\r\nConnection: keep-alive\r\nContent-Length: 10\r\n\r\nfoo=569789a${sep}GET /kill:$$:USR1,status HTTP/1.0\r\n\r\n";
    like(scalar <$sock>, qr/200 OK/, "200 to POST w/ pipelined GET after");
    select undef, undef, undef, 0.25;
    ok(!$gotsig, "didn't get signal from GET after POST");
}

$sock = $get_sock->();
print $sock "GET /status HTTP/1.0\r\n\r\n";
like(scalar <$sock>, qr/200 OK/, "single GET okay");

$sock = $get_sock->();
print $sock "GET /status HTTP/1.0\r\n\r\nGET /status HTTP/1.0\r\n\r\n";
like(scalar <$sock>, qr/\b400\b/, "pipelined when not expecting it");





sub add_all {
    foreach (@web_ports) {
        manage("POOL a ADD 127.0.0.1:$_") or die;
    }
}

1;
