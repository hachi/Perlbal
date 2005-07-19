#!/usr/bin/perl

package Perlbal::Test::WebServer;

use strict;
use IO::Socket::INET;
use HTTP::Request;
use Socket qw(MSG_NOSIGNAL IPPROTO_TCP TCP_NODELAY SOL_SOCKET);
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
        print $sock "GET /reqdecr,status HTTP/1.0\r\n\r\n";
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
        setsockopt($csock, IPPROTO_TCP, TCP_NODELAY, pack("l", 1)) or die;
        serve_client($csock);
    }
}

sub serve_client {
    my $csock = shift;
    my $req_num = 0;
    my @reqs;

  REQ:
    while (1) {
        my $req = '';
        while (<$csock>) {
            $req .= $_;
            last if ! $_ || /^\r?\n/;
        }

        # parse out things we want to have
        my @cmds;
        my $httpver; # 0 = 1.0, 1 = 1.1, undef = neither
        if ($req =~ m!^GET /(\S+) HTTP/(1\.\d+)\r?\n?!) {
            my $cmds = durl($1);
            @cmds = split(/\s*,\s*/, $cmds);
            $req_num++;
            $httpver = ($2 eq '1.0' ? 0 : ($2 eq '1.1' ? 1 : undef));
        }
        my $msg = HTTP::Request->parse($req);
        my $keeping_alive = undef;

        my $response = sub {
            my ($code, $codetext, $content, $ctype) = @_;
            $codetext ||= { 200 => 'OK', 500 => 'Internal Server Error' }->{$code};
            $content ||= "$code $codetext";
            my $clen = length $content;
            $ctype ||= "text/plain";
            my $hdr_keepalive = "";

            unless (defined $keeping_alive) {
                if ($httpver == 1) {
                    if ($msg->header("Connection") =~ /\bclose\b/i) {
                        $keeping_alive = 0;
                    } else {
                        $keeping_alive = "1.1implicit";
                    }
                }
                if ($httpver == 0 && $msg->header("Connection") =~ /\bkeep-alive\b/i) {
                    $keeping_alive = "1.0keepalive";
                }
            }

            if ($keeping_alive) {
                $hdr_keepalive = "Connection: keep-alive\n";
            } else {
                $hdr_keepalive = "Connection: close\n";
            }

            return "HTTP/1.0 $code $codetext\r\n" .
                "Content-Type: $ctype\r\n" .
                $hdr_keepalive .
                "Content-Length: $clen\r\n" .
                "\r\n" .
                "$content";
        };

        my $send = sub {
            my $res = shift;
            print $csock $res;
            exit 0 unless $keeping_alive;
        };

        # 500 if no commands were given or we don't know their HTTP version
        # or we didn't parse a proper HTTP request
        unless (@cmds && defined $httpver && $msg) {
            $send->($response->(500));
            next REQ;
        }

        # prepare a simple 200 to send; undef this if you want to control
        # your own output below
        my $to_send = $response->(200);

        foreach my $cmd (@cmds) {
            $cmd =~ s/^\s+//;
            $cmd =~ s/\s+$//;

            if ($cmd =~ /^sleep:([\d\.]+)$/i) {
                select undef, undef, undef, $1;
            }

            if ($cmd =~ /^keepalive:([01])$/i) {
                $keeping_alive = $1;
            }

            if ($cmd eq "status") {
                $to_send = $response->(200, undef, "pid = $$\nreqnum = $req_num\n");
            }

            if ($cmd eq "reqdecr") {
                $req_num--;
            }
        }

        if (defined $to_send) {
            $send->($to_send);
            next REQ;
        }
    } # while(1)
}

# de-url escape
sub durl {
    my ($a) = @_;
    $a =~ tr/+/ /;
    $a =~ s/%([a-fA-F0-9][a-fA-F0-9])/pack("C", hex($1))/eg;
    return $a;
}

1;
