######################################################################
# Service class
######################################################################

package Perlbal::Service;

sub new {
    my ($class, $name) = @_;
    my $self = {
	name => $name,
	enabled => 0,
    };
    return bless $self, ref $class || $class;
}

sub get_backend_endpoint {
    return ("10.1.0.10", "80");
}

# getter only
sub role {
    my $self = shift;
    return $self->{role};
}

# Service
sub set {
    my ($self, $key, $val, $out) = @_;
    my $err = sub { $out->("ERROR: $_[0]"); return 0; };
    my $set = sub { $self->{$key} = $val;   return 1; };

    if ($key eq "role") {
	return $err->("Unknown service role")
	    unless $val eq "reverse_proxy" || $val eq "management";
	return $set->();
    }

    if ($key eq "listen") {
	return $err->("Invalid host:port")
	    unless $val =~ m!^\d+\.\d+\.\d+\.\d+:\d+$!;
	return $set->();
    }

    if ($key eq "balance_method") {
	return $err->("Can only set balance method on a reverse_proxy service")
	    unless $self->{role} eq "reverse_proxy";
	return $err->("Unknown balance method")
	    unless $val eq "sendstats";
	return $set->();
    }

    if ($key eq "nodefile") {
	return $err->("File not found")
	    unless -e $val;
	return $set->();
    }

    if ($key =~ /^sendstats\./) {
	return $err->("Can only set sendstats listening address on service with balancing method 'sendstats'")
	    unless $self->{balance_method} eq "sendstats";
	if ($key eq "sendstats.listen") {
	    return $err->("Invalid host:port")
		unless $val =~ m!^\d+\.\d+\.\d+\.\d+:\d+$!;

	    if (my $pbs = $self->{"sendstats.listen.SOCKET"}) {
		$pbs->close;
	    }

	    unless ($self->{"sendstats.listen.SOCKET"} =
		    Perlbal::StatsListener->new($val, $self)) {
		return $err->("Error creating stats listener: $Perlbal::last_error");
	    }
	}
	return $set->();
    }

    return $err->("Unknown attribute '$key'");
}

# Service
sub enable {
    my ($self, $out) = @_;
    if ($self->{enabled}) {
	$out->("ERROR: service $self->{name} is already enabled");
	return 0;
    }

    # create listening socket
    my $tl = Perlbal::TCPListener->new($self->{listen}, $self);
    unless ($tl) {
	$out->("Can't start service '$self->{name}' on $self->{listen}: $Perlbal::last_error");
	return 0;
    }

    $self->{listener} = $tl;
    $self->{enabled} = 1;
    return 1;
}

# Service
sub disable {
    my ($self, $out) = @_;
    if (! $self->{enabled}) {
	$out->("ERROR: service $self->{name} is already disabled");
	return 0;
    }
    if ($self->{role} eq "management") {
	$out->("ERROR: can't disable management service");
        return 0;
    }

    # find listening socket
    my $tl = $self->{listener};
    $tl->close;
    $self->{listener} = undef;
    $self->{enabled} = 0;
    return 1;
}

1;
