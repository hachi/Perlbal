######################################################################
# TCP listener on a given port
######################################################################

package Perlbal::TCPListener;
use base "Perlbal::Socket";
use fields qw(service);

# TCPListener
sub new {
    my ($class, $hostport, $service) = @_;

    my $sock = IO::Socket::INET->new(
                                     LocalAddr => $hostport,
                                     Proto => 'tcp',
                                     Listen => 1024,
                                     ReuseAddr => 1,
                                     Blocking => 0,
                                     );

    return Perlbal::error("Error creating listening socket: $!")
	unless $sock;

    my $self = $class->SUPER::new($sock);
    $self->{service} = $service;
    bless $self, ref $class || $class;
    $self->watch_read(1);
    return $self;
}

# TCPListener: accepts a new client connection
sub event_read {
    my Perlbal::TCPListener $self = shift;

    # new connection
    my ($psock, $peeraddr) = $self->{sock}->accept();
    unless ($psock) {
	print STDERR "No remote sock?\n";
	return;
    }

    print "Got new conn: $psock\n" if Perlbal::DEBUG >= 1;
    IO::Handle::blocking($psock, 0);

    my $service_role = $self->{service}->role;
    if ($service_role eq "reverse_proxy") {
	Perlbal::ClientProxy->new($self->{service}, $psock);
    } elsif ($service_role eq "management") {
	Perlbal::ClientManage->new($self->{service}, $psock);
    }
}

1;
