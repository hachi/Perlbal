#!/usr/bin/perl

use strict;
use Perlbal::Test;
use Test::More 'no_plan';

use Perlbal;
use Perlbal::HTTPHeaders;
eval "use Perlbal::XS::HTTPHeaders 0.20;";

# classes we will be testing
my @classes = ('Perlbal::HTTPHeaders');
push @classes, $Perlbal::XSModules{headers}
    if $Perlbal::XSModules{headers};

# verify they work
foreach my $class (@classes) {
    # basic request, just tests to see if the class is functioning
    my $req = \ "GET / HTTP/1.0\r\n\r\n";
    my $c_req = $class->new($req);
    ok($c_req, "basic request - $class");

    # basic response, same
    my $resp = \ "HTTP/1.0 200 OK\r\n\r\n";
    my $c_resp = $class->new($resp, 1);
    ok($c_resp, "basic response - $class");

    # test for a bug in the XS headers that caused headers with no content
    # to be disconnected from the server
    my $hdr = \ "GET / HTTP/1.0\r\nHeader: content\r\nAnother: \r\nSomething:\r\n\r\n";
    my $obj = $class->new($hdr);
    ok($obj, "headers without content 1 - $class");
    is($obj->header('header'), 'content', "headers without content 2 - $class");
    is($obj->header('anoTHER'), '', "headers without content 3 - $class");
    is($obj->header('notthere'), undef, "headers without content 4 - $class");

    is_deeply([sort @{ $obj->headers_list }], [qw/ another header something /], 'headers_list');
}

1;
