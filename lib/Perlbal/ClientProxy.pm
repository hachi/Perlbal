######################################################################
# HTTP Connection from a reverse proxy client
######################################################################

package Perlbal::ClientProxy;
use strict;
use base "Perlbal::Socket";
use fields ('service',             # Perlbal::Service object
	    'backend',             # Perlbal::BackendHTTP object (or undef if disconnected)
	    'all_sent',            # scalar bool: if writing is done
	    'reconnect_count',     # number of times we've tried to reconnect to backend

	    # reproxy support
	    'reproxy_file',        # filename the backend told us to start opening
	    'reproxy_file_size',   # size of file, once we stat() it
	    'reproxy_fd',          # integer fd of reproxying file, once we open() it
	    'reproxy_file_offset', # how much we've sent from the file.
	    );

use constant READ_SIZE         => 4086;    # 4k, arbitrary
use constant READ_AHEAD_SIZE   => 8192;    # 8k, arbitrary
use Errno qw( EPIPE );
use POSIX ();

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

sub start_reproxy_file {
    my Perlbal::ClientProxy $self = shift; 
    my $file = shift;                      # filename to reproxy
    my Perlbal::HTTPHeaders $hd = shift;   # headers from backend, in need of cleanup

    # start an async stat on the file
    Linux::AIO::aio_stat($file, sub {

	# if the client's since disconnected by the time we get the stat,
	# just bail.
	return if $self->{closed};

	my $size = -s _;

	unless ($size) {
	    # FIXME: POLICY: 404 or retry request to backend w/o reproxy-file capability?
	    # for now we just close the connection, which is kinda lame.
	    print STDERR "REPROXY: $file (bogus)\n";
	    $self->close;
	    return;
	}

	# fixup the Content-Length header with the correct size (application
	# doesn't need to provide a correct value if it doesn't want to stat())
	$hd->header("Content-Length", $size);
	# don't send this internal header to the client:
	$hd->header('X-REPROXY-FILE', undef);

	# just send the header, now that we cleaned it.
	$self->write($hd->to_string_ref);

	if ($self->{headers}->request_method eq 'HEAD') {
	    $self->all_sent(1);
	    return;
	}
		
	Linux::AIO::aio_open($file, 0, 0 , sub {
	    my $rp_fd = shift;

	    # if client's gone, just close filehandle and abort
	    if ($self->{closed}) {
		POSIX::close($rp_fd) if $rp_fd >= 0;
		return;
	    }
	    
	    # handle errors
	    if ($rp_fd < 0) {
		# couldn't open the file we had already successfully stat'ed.
		# FIXME: do 500 vs. 404 vs whatever based on $!
		return $self->close();
	    }

	    $self->reproxy_fd($rp_fd, $size);
	    $self->watch_write(1);
	});
    });
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

# Client (overrides and calls super)
sub close {
    my Perlbal::ClientProxy $self = shift;
    my $reason = shift;

    # kill our backend if we still have one
    if (my $backend = $self->{backend}) {
	print "Client ($self) closing backend ($backend)\n" if Perlbal::DEBUG >= 1;
	$self->backend(undef);
	$backend->close($reason ? "proxied_from_client_close:$reason" : "proxied_from_client_close");
    }

    # close the file we were reproxying, if any
    POSIX::close($self->{reproxy_fd}) if $self->{reproxy_fd};

    $self->SUPER::close($reason);
}

# Client
sub reproxy_fd {
    my Perlbal::ClientProxy $self = shift;
    return $self->{reproxy_fd} unless @_;

    my ($fd, $size) = @_;
    $self->{reproxy_file_offset} = 0;
    $self->{reproxy_file_size} = $size;
    return $self->{reproxy_fd} = $fd;
}

# Client
sub event_write { 
    my Perlbal::ClientProxy $self = shift;

    if ($self->{reproxy_fd}) {
	my $to_send = $self->{reproxy_file_size} - $self->{reproxy_file_offset};
	$self->tcp_cork(1) if $self->{reproxy_file_offset} == 0;
	my $sent = IO::SendFile::sendfile($self->{fd}, 
					  $self->{reproxy_fd},
					  0, # NULL offset means kernel moves filepos (apparently)
					  $to_send);
	print "REPROXY Sent: $sent\n" if Perlbal::DEBUG >= 2;
	if ($sent < 0) { 
	    if ($! == EPIPE) {
		$self->close("epipe");
		return;
	    }
	    print STDERR "Error w/ sendfile: $!\n"; 
	    $self->close;
	    return;
	}
	$self->{reproxy_file_offset} += $sent;

	if ($sent >= $to_send) {
	    # close the sendfile fd
	    my $rv = POSIX::close($self->{reproxy_fd});

	    $self->tcp_cork(0);
	    $self->{reproxy_fd} = undef;
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
