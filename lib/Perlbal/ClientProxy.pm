######################################################################
# HTTP Connection from a reverse proxy client
######################################################################

package Perlbal::ClientProxy;
use strict;
use base "Perlbal::Socket";
use fields qw(service backend all_sent reproxy_file reconnect_count
	      reproxy_file_offset reproxy_file_size );

use constant READ_SIZE         => 4086;    # 4k, arbitrary
use constant READ_AHEAD_SIZE   => 8192;    # 8k, arbitrary

# ClientProxy
sub new {
    my ($class, $service, $sock) = @_;

    my $self = fields::new($class);
    $self->SUPER::new($sock);       # init base fields

    $self->{service} = $service;

    $self->{headers} = undef;      # defined w/ headers object once all headers in
    $self->{headers_string} = "";  # blank to start

    $self->{read_buf} = [];        # scalar refs of bufs read from client
    $self->{read_ahead} = 0;       # bytes sitting in read_buf
    $self->{read_size} = 0;        # total bytes read from client
 
    $self->{backend} = undef;
    $self->{all_sent} = 0;         # boolean: backend has written all data to client

    bless $self, ref $class || $class;
    $self->watch_read(1);
    return $self;
}

# Client
# get/set backend proxy connection
sub all_sent {
    my Perlbal::ClientProxy $self = shift;
    return $self->{all_sent} unless @_;
    return $self->{all_sent} = shift;
}

# Client
# get/set backend proxy connection
sub backend {
    my Perlbal::ClientProxy $self = shift;
    return $self->{backend} unless @_;
    return $self->{backend} = shift;
}

# Client
# get/set headers
sub headers {
    my Perlbal::ClientProxy $self = shift;
    return $self->{headers} unless @_;
    return $self->{headers} = shift;
}

sub request_method {
    my Perlbal::ClientProxy $self = shift;
    return $self->{headers}->request_method;
}

# Client (overrides and calls super)
sub close {
    my Perlbal::ClientProxy $self = shift;
    my $reason = shift;
    if (my $backend = $self->{backend}) {
	print "Client ($self) closing backend ($backend)\n" if Perlbal::DEBUG >= 1;
	$self->backend(undef);
	$backend->close($reason ? "proxied_from_client_close:$reason" : "proxied_from_client_close");
    }
    $self->SUPER::close($reason);
}

# Client
sub reproxy_file {
    my Perlbal::ClientProxy $self = shift;
    return $self->{reproxy_file} unless @_;
    my ($fh, $size) = @_;
    $self->{reproxy_file_offset} = 0;
    $self->{reproxy_file_size} = $size;
    return $self->{reproxy_file} = $fh;
}

# Client
sub event_write { 
    my Perlbal::ClientProxy $self = shift;

    if ($self->{reproxy_file}) {
	my $to_send = $self->{reproxy_file_size} - $self->{reproxy_file_offset};
	$self->tcp_cork(1) if $self->{reproxy_file_offset} == 0;
	my $sent = IO::SendFile::sendfile($self->{fd}, 
					  fileno($self->{reproxy_file}),
					  0, # NULL offset means kernel moves filepos (apparently)
					  $to_send);
	print "REPROXY Sent: $sent\n" if Perlbal::DEBUG >= 2;
	if ($sent < 0) { die "Error w/ sendfile: $!\n"; }
	$self->{reproxy_file_offset} += $sent;

	if ($sent >= $to_send) {
	    $self->tcp_cork(0);
	    $self->{reproxy_file} = undef;
	    $self->close("sendfile_done");
	    $self->all_sent(1);  # set our own flag that we're done
	}
	return;
    }

    if ($self->write(undef)) {
	print "All writing done to $self\n" if Perlbal::DEBUG >= 2;

	# we've written all data in the queue, so stop waiting for write
	# notifications:
	$self->watch_write(0);

	if ($self->all_sent) {
	    # backend has notified us that it's pushed all its
	    # data into our queue.  so if we're caught up
	    # at this point, that means we're done.

	    $self->close("writing_done");
	}
    }

    # trigger our backend to keep reading, if it's still connected
    my $backend = $self->backend;
    $backend->watch_read(1) if $backend && ! $self->all_sent;
}

# ClientProxy
sub event_read {
    my Perlbal::ClientProxy $self = shift;

    unless ($self->{headers}) {
	if (my $hd = $self->read_request_headers) {
	    print "Got headers!  Firing off new backend connection.\n"
		if Perlbal::DEBUG >= 2;

	    # useful for profiling:
	    exit 0 if Perlbal::SHUTDOWN_BY_CLIENT && $hd->header("X-TEMP-SHUTDOWN");

	    my $be = Perlbal::BackendHTTP->new($self);

	    # abort if we couldn't get a backend host
	    return $self->close unless $be;

	    $self->tcp_cork(1);  # cork writes to self
	}
	return;
    }

    if ($self->{read_ahead} < READ_AHEAD_SIZE) {
	my $bref = $self->read(READ_SIZE);
	my $backend = $self->backend;
	$self->drain_read_buf_to($backend) if $backend;

	if (! defined($bref)) {
	    $self->watch_read(0);
	    return;
	}

	my $len = length($$bref);
	$self->{read_size} += $len;

	if ($backend) {
	    $backend->write($bref);
	} else {
	    push @{$self->{read_buf}}, $bref;
	    $self->{read_ahead} += $len;
	}

    } else {

	$self->watch_read(0);
    }
}

sub event_err {  my $self = shift; $self->close; }
sub event_hup {  my $self = shift; $self->close; }

1;
