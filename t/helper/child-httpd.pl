#!/usr/bin/perl

use strict;
my $req = <>;
die "Bogus request" unless $req =~ /^GET (\/\S*) HTTP\/1\.\d/;

$| = 1;

my $uri = $1;
while (<>) {
    last unless /\S/;
}

my $response = "You wanted [$uri] and I am pid=$$\n";
#warn "Response from pid $$: [$response]\n";
my $len = length $response;
print "HTTP/1.0 200 OK\r\nContent-Length: $len\r\n\r\n$response";

