######################################################################
# TCP listener on a given port
#
# Copyright 2004, Danga Interactive, Inc.
# Copyright 2005-2007, Six Apart, Ltd.


package Perlbal::TCPListener;
use strict;
use warnings;
no  warnings qw(deprecated);

use base "Perlbal::Socket";
use fields ('service',
            'hostport',
            'sslopts',
            'v6',  # bool: IPv6 libraries are available
            );
use Socket qw(IPPROTO_TCP SOL_SOCKET SO_SNDBUF);

BEGIN {
    eval { require Perlbal::SocketSSL };
    if (Perlbal::DEBUG > 0 && $@) { warn "SSL support failed on load: $@\n" }
}

# TCPListener
sub new {
    my Perlbal::TCPListener $self = shift;
    my ($hostport, $service, $opts) = @_;

    $self = fields::new($self) unless ref $self;
    $opts ||= {};

    # Were ipv4 or ipv6 explicitly mentioned by syntax?
    my $force_v4 = 0;
    my $force_v6 = 0;

    my @args;
    if ($hostport =~ /^\d+$/) {
        @args = ('LocalPort' => $hostport);
    } elsif ($hostport =~ /^\d+\.\d+\.\d+\.\d+:/) {
        $force_v4 = 1;
        @args = ('LocalAddr' => $hostport);
    }

    my $v6_errors = "";

    my $can_v6 = 0;
    if (!$force_v4) {
        eval "use Danga::Socket 1.61; 1; ";
        if ($@) {
            $v6_errors = "Danga::Socket 1.61 required for IPv6 support.";
        } elsif (!eval { require IO::Socket::INET6; 1 }) {
            $v6_errors = "IO::Socket::INET6 required for IPv6 support.";
        } else {
            $can_v6 = 1;
        }
    }

    my $socket_class = $can_v6 ? "IO::Socket::INET6" : "IO::Socket::INET";
    $self->{v6} = $can_v6;

    my $sock = $socket_class->new(
                                  @args,
                                  Proto => IPPROTO_TCP,
                                  Listen => 1024,
                                  ReuseAddr => 1,
                                  );

    return Perlbal::error("Error creating listening socket: " . ($@ || $!))
        unless $sock;

    if ($^O eq 'MSWin32') {
        # On Windows, we have to do this a bit differently.
        # IO::Socket should really do this for us, but whatever.
        my $do = 1;
        ioctl($sock, 0x8004667E, \$do) or return Perlbal::error("Unable to make listener on $hostport non-blocking: $!");
    }
    else {
        # IO::Socket::INET's Blocking => 0 just doesn't seem to work
        # on lots of perls.  who knows why.
        IO::Handle::blocking($sock, 0) or return Perlbal::error("Unable to make listener on $hostport non-blocking: $!");
    }

    $self->SUPER::new($sock);
    $self->{service} = $service;
    $self->{hostport} = $hostport;
    $self->{sslopts} = $opts->{ssl};
    $self->watch_read(1);
    return $self;
}

# TCPListener: accepts a new client connection
sub event_read {
    my Perlbal::TCPListener $self = shift;

    # accept as many connections as we can
    while (my ($psock, $peeraddr) = $self->{sock}->accept) {
        IO::Handle::blocking($psock, 0);

        if (my $sndbuf = $self->{service}->{client_sndbuf_size}) {
            my $rv = setsockopt($psock, SOL_SOCKET, SO_SNDBUF, pack("L", $sndbuf));
        }

        if (Perlbal::DEBUG >= 1) {
            my ($pport, $pipr) = $self->{v6} ?
                Socket6::unpack_sockaddr_in6($peeraddr) :
                Socket::sockaddr_in($peeraddr);
            my $pip = $self->{v6} ?
                "[" . Socket6::inet_ntop(Socket6::AF_INET6(), $pipr) . "]" :
                Socket::inet_ntoa($pipr);
            print "Got new conn: $psock ($pip:$pport) for " . $self->{service}->role . "\n";
        }

        # SSL promotion if necessary
        if ($self->{sslopts}) {
            # try to upgrade to SSL, this does no IO it just re-blesses
            # and prepares the SSL engine for handling us later
            IO::Socket::SSL->start_SSL(
                                       $psock,
                                       SSL_server => 1,
                                       SSL_startHandshake => 0,
                                       %{ $self->{sslopts} },
                                       );
            print "  .. socket upgraded to SSL!\n" if Perlbal::DEBUG >= 1;

            # safety checking to ensure we got upgraded
            return $psock->close
                unless ref $psock eq 'IO::Socket::SSL';

            # class into new package and run with it
            my $sslsock = new Perlbal::SocketSSL($psock, $self);
            $sslsock->try_accept;

            # all done from our point of view
            next;
        }

        # puts this socket into the right class
        $self->class_new_socket($psock);
    }
}

sub class_new_socket {
    my Perlbal::TCPListener $self = shift;
    my $psock = shift;

    my $service_role = $self->{service}->role;
    if ($service_role eq "reverse_proxy") {
        return Perlbal::ClientProxy->new($self->{service}, $psock);
    } elsif ($service_role eq "management") {
        return Perlbal::ClientManage->new($self->{service}, $psock);
    } elsif ($service_role eq "web_server") {
        return Perlbal::ClientHTTP->new($self->{service}, $psock);
    } elsif ($service_role eq "selector") {
        # will be cast to a more specific class later...
        return Perlbal::ClientHTTPBase->new($self->{service}, $psock, $self->{service});
    } elsif (my $creator = Perlbal::Service::get_role_creator($service_role)) {
        # was defined by a plugin, so we want to return one of these
        return $creator->($self->{service}, $psock);
    }
}

sub as_string {
    my Perlbal::TCPListener $self = shift;
    my $ret = $self->SUPER::as_string;
    my Perlbal::Service $svc = $self->{service};
    $ret .= ": listening on $self->{hostport} for service '$svc->{name}'";
    return $ret;
}

sub as_string_html {
    my Perlbal::TCPListener $self = shift;
    my $ret = $self->SUPER::as_string_html;
    my Perlbal::Service $svc = $self->{service};
    $ret .= ": listening on $self->{hostport} for service <b>$svc->{name}</b>";
    return $ret;
}

sub die_gracefully {
    # die off so we stop waiting for new connections
    my $self = shift;
    $self->close('graceful_death');
}

1;


# Local Variables:
# mode: perl
# c-basic-indent: 4
# indent-tabs-mode: nil
# End:
