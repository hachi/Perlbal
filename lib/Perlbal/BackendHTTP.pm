######################################################################
# HTTP connection to backend node
######################################################################

package Perlbal::BackendHTTP;
use strict;
use base "Perlbal::Socket";
use fields qw(client ip port req_sent);

use constant BACKEND_READ_SIZE => 131072;  # 128k; arbitrary

# Backend
sub new {
    my ($class, $client) = @_;

    my $svc = $client->{service};
    my ($ip, $port) = $svc->get_backend_endpoint();
    return undef unless $ip;

    my $sock = IO::Socket::INET->new(
				     PeerAddr => $ip,
				     PeerPort => $port,
                                     Proto => 'tcp',
                                     Blocking => 0,
                                     );

    my $self = fields::new($class);
    $self->SUPER::new($sock);

    $self->{client} = $client;   # client Perlbal::Socket this backend conn is for
    $self->{client}->backend($self);  # set client's backend to us

    $self->{ip}     = $ip;       # backend IP
    $self->{port}   = $port;     # backend port

    # for header reading:
    $self->{headers} = undef;      # defined w/ headers object once all headers in
    $self->{headers_string} = "";  # blank to start
    $self->{read_buf} = [];        # scalar refs of bufs read from client
    $self->{read_ahead} = 0;       # bytes sitting in read_buf
    $self->{read_size} = 0;        # total bytes read from client

    $self->{req_sent} = 0;         # boolean; request sent to backend?

    bless $self, ref $class || $class;
    $self->watch_write(1);
    return $self;
}

# Backend
sub event_write {
    my Perlbal::BackendHTTP $self = shift;
    print "Backend $self is writeable!\n" if Perlbal::DEBUG >= 2;

    my $done;
    unless ($self->{req_sent}++) {
	my $hds = $self->{client}->headers;

	# FIXME: make this conditional
	$hds->header("X-Proxy-Capabilities", "reproxy-file");

	$self->tcp_cork(1);
	$done = $self->write($hds->to_string_ref);
	$self->write(sub { 
	    $self->tcp_cork(0);
	    if (my $client = $self->{client}) {
		# make the client push its overflow reads (request body)
		# to the backend
		$client->drain_read_buf_to($self);
		# and start watching for more reads
		$client->watch_read(1);
	    }
	});
    }
    
    $done = $self->write(undef);
    if ($done) {
	$self->watch_read(1);
	$self->watch_write(0);
    }
}

# Backend
sub event_read {
    my Perlbal::BackendHTTP $self = shift;
    print "Backend $self is readable!\n" if Perlbal::DEBUG >= 2;

    my Perlbal::ClientProxy $client = $self->{client};

    unless ($self->{headers}) {
	if (my $hd = $self->read_response_headers) {

	    if (my $rep = $hd->header('X-REPROXY-FILE')) {
		if (my $size = -s $rep) {
		    my $fh = new IO::File;
		    open($fh, $rep) or return $client->close("reproxy_file_open_error");
		    $client->reproxy_file($fh, $size);

		    # fixup the Content-Length header if it was undefined/0
		    $hd->header("Content-Length", $size);
		    # don't send this internal header to the client:
		    $hd->header('X-REPROXY-FILE', undef);

		    # setup the client's state:
		    $client->write($hd->to_string_ref);
		    $client->backend(undef);    # disconnect ourselves from it
		    $self->{client} = undef;    # .. and it from us
		    $self->close;               # close ourselves
		    $client->watch_write(1);    # and kick-start it into writing
		} else {
		    print STDERR "REPROXY: $rep (bogus)\n";
		    $client->close;
		}
		
	    } else {
		$client->write($hd->to_string_ref);
		$self->drain_read_buf_to($client);
	    }


	}
	return;
    }

    # if our client's 250k behind, stop buffering
    # FIXME: constant
    if ($client->{write_buf_size} > 256_000) { 
	$self->watch_read(0);
	return;
    }

    my $bref = $self->read(BACKEND_READ_SIZE);

    if (defined $bref) {
	$client->write($bref);
	return;
    } else {
	# backend closed
	print "Backend $self is done; closing...\n" if Perlbal::DEBUG >= 1;
	
	$client->backend(undef);    # disconnect ourselves from it
	$self->{client} = undef;    # .. and it from us
	$self->close;               # close ourselves
	
	$client->write(sub { $client->tcp_cork(0); });
	$client->all_sent(1);      # tell our old client it has everything it needs
	$client->watch_write(1);   # and kick-start it into writing (or shutting down)
	return;
    }
}

# Backend: bad connection to backend
sub event_err {
    my Perlbal::BackendHTTP $self = shift;

    # FIXME: we get this after backend is done reading and we disconnect,
    # hence the misc checks below for $self->{client}.

    print "BACKEND event_err\n" if
	Perlbal::DEBUG >= 2;

    if ($self->{req_sent}) {
	# request already sent to backend, then an error occurred.
	# we don't want to duplicate POST requests, so for now
	# just fail
	# TODO: if just a GET request, retry?
	$self->{client}->close if $self->{client};
	$self->close;
	return;
    }

    # otherwise, retry connection up to 5 times (FIXME: arbitrary)
    my Perlbal::ClientProxy $client = $self->{client};
    Perlbal::BackendHTTP->new($client)
	if $client && ! $client->{closed} && 
	++$client->{reconnect_count} < 5;

    $self->close("error");
}

# Backend
sub event_hup {
    my Perlbal::BackendHTTP $self = shift;
    print "HANGUP for $self\n";
}

1;
