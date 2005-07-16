#!/usr/bin/perl

package Perlbal::Test::WebServer;

use strict;
use IO::Socket::INET;
use Perlbal::Test;

require Exporter;
use vars qw(@ISA @EXPORT);
@ISA = qw(Exporter);
@EXPORT = qw(start_webserver);

our @webserver_pids;

END {
    # ensure we kill off the webserver
    kill 9, @webserver_pids;
}

sub start_webserver {
    my $port = new_port();

    if (my $child = fork) {
        # i am parent, wait for child to startup
        push @webserver_pids, $child;
        my $sock = wait_on_child($child, $port);
        die "Unable to spawn webserver on port $port\n"
            unless $sock;
        print $sock "GET /status HTTP/1.0\r\n\r\n";
        my $line = <$sock>;
        die "Didn't get 200 OK: $line"
            unless $line =~ /200 OK/;
        return $port;
    }

    # i am child, start up
    my $ssock = IO::Socket::INET->new(LocalPort => $port, ReuseAddr => 1, Listen => 3)
        or die "Unable to start socket: $!\n";
    while (my $csock = $ssock->accept) {
        exit 0 unless $csock;
        fork and next; # parent starts waiting for next request

        my $eat = sub {
            while (<$csock>) {
                last if ! $_ || /^\r?\n/;
            }
        };
        my $response = sub {
            my ($code, $msg, $content, $ctype) = @_;
            $msg ||= { 200 => 'OK', 500 => 'Internal Server Error' }->{$code};
            $content ||= "$code $msg";
            my $clen = length $content;
            $ctype ||= "text/plain";
            return "HTTP/1.0 $code $msg\r\n" .
                   "Content-Type: $ctype\r\n" .
                   "Content-Length: $clen\r\n" .
                   "\r\n" .
                   "$content";
        };

        my $req = <$csock>;

        my @cmds;
        if ($req =~ m!^GET /(\S+) HTTP/1\.\d+\r?\n?$!) {
            @cmds = split(/\s*,\s*/, durl($1));
        }

        # 500 if no commands were given
        unless (@cmds) {
            print $csock $response->(500);
            exit 0;
        }

        # prepare a simple 200 to send; undef this if you want to control
        # your own output below
        my $to_send = $response->(200);

        foreach my $cmd (@cmds) {
            $cmd =~ s/^\s+//;
            $cmd =~ s/\s+$//;

            if ($cmd =~ /^sleep\s+(\d+)$/i) {
                sleep $1+0;
            }
            
            if ($cmd =~ /^status$/i) {
                $to_send = $response->(200, undef, "pid = $$");
            }
        }

        if (defined $to_send) {
            print $csock $to_send;
        }
        exit 0;
    }
    exit 0;
}

# de-url escape
sub durl {
    my ($a) = @_;
    $a =~ tr/+/ /;
    $a =~ s/%([a-fA-F0-9][a-fA-F0-9])/pack("C", hex($1))/eg;
    return $a;
}

1;
