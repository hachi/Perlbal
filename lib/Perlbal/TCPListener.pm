######################################################################
# TCP listener on a given port
######################################################################

package Perlbal::TCPListener;
use strict;
use base "Perlbal::Socket";
use fields qw(service hostport);
use Socket qw(IPPROTO_TCP SO_KEEPALIVE TCP_NODELAY SOL_SOCKET);

# Linux-specific:
use constant TCP_KEEPIDLE  => 4; # Start keeplives after this period
use constant TCP_KEEPINTVL => 5; # Interval between keepalives
use constant TCP_KEEPCNT   => 6; # Number of keepalives before death

# TCPListener
sub new {
    my ($class, $hostport, $service) = @_;

    my $sock = IO::Socket::INET->new(
                                     LocalAddr => $hostport,
                                     Proto => IPPROTO_TCP,
                                     Listen => 1024,
                                     ReuseAddr => 1,
                                     Blocking => 0,
                                     );

    return Perlbal::error("Error creating listening socket: $!")
        unless $sock;

    my $self = $class->SUPER::new($sock);
    $self->{service} = $service;
    $self->{hostport} = $hostport;
    bless $self, ref $class || $class;
    $self->watch_read(1);
    return $self;
}

# TCPListener: accepts a new client connection
sub event_read {
    my Perlbal::TCPListener $self = shift;

    # accept as many connections as we can
    while (my ($psock, $peeraddr) = $self->{sock}->accept) {
        my $service_role = $self->{service}->role;

        if (Perlbal::DEBUG >= 1) {
            my ($pport, $pipr) = Socket::sockaddr_in($peeraddr);
            my $pip = Socket::inet_ntoa($pipr);
            print "Got new conn: $psock ($pip:$pport) for $service_role\n";
        }

        IO::Handle::blocking($psock, 0);

        # Linux-specific, enable keep alive (for 2.5 minutes)
        (setsockopt($psock, SOL_SOCKET, SO_KEEPALIVE,  pack("l", 1)) &&
         setsockopt($psock, IPPROTO_TCP, TCP_KEEPIDLE,  pack("l", 30)) &&
         setsockopt($psock, IPPROTO_TCP, TCP_KEEPCNT,   pack("l", 2)) &&   
         setsockopt($psock, IPPROTO_TCP, TCP_KEEPINTVL, pack("l", 30)) &&
         1
         ) || die "Couldn't set keep-alive settings on socket (Not on Linux?)";
        
        if ($service_role eq "reverse_proxy") {
            Perlbal::ClientProxy->new($self->{service}, $psock);
        } elsif ($service_role eq "management") {
            Perlbal::ClientManage->new($self->{service}, $psock);
        } elsif ($service_role eq "web_server") {
            Perlbal::ClientHTTP->new($self->{service}, $psock);
        }
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


1;


# Local Variables:
# mode: perl
# c-basic-indent: 4
# indent-tabs-mode: nil
# End:
