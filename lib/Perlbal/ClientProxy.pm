######################################################################
# HTTP Connection from a reverse proxy client
######################################################################

package Perlbal::ClientProxy;
use strict;
use warnings;
use base "Perlbal::ClientHTTPBase";
use fields (
            'backend',             # Perlbal::BackendHTTP object (or undef if disconnected)
            'reconnect_count',     # number of times we've tried to reconnect to backend
            'high_priority',       # boolean; 1 if we are or were in the high priority queue
            'reproxy_uris',        # arrayref; URIs to reproxy to, in order
            'reproxy_expected_size', # int: size of response we expect to get back for reproxy
            'content_length_remain', # int: amount of data we're still waiting for
            'responded',           # bool: whether we've already sent a response to the user or not
            );

use constant READ_SIZE         => 4086;    # 4k, arbitrary
use constant READ_AHEAD_SIZE   => 8192;    # 8k, arbitrary
use Errno qw( EPIPE );
use POSIX ();

# ClientProxy
sub new {
    my ($class, $service, $sock) = @_;

    my $self = $class;
    $self = fields::new($class) unless ref $self;
    $self->SUPER::new($service, $sock);       # init base fields

    Perlbal::objctor();

    $self->{read_buf} = [];        # scalar refs of bufs read from client
    $self->{read_ahead} = 0;       # bytes sitting in read_buf
    $self->{read_size} = 0;        # total bytes read from client

    $self->{backend} = undef;
    $self->{high_priority} = 0;

    $self->{responded} = 0;
    $self->{content_length_remain} = undef;

    $self->{reproxy_uris} = undef;
    $self->{reproxy_expected_size} = undef;

    bless $self, ref $class || $class;
    $self->watch_read(1);
    return $self;
}

# call this with a string of space separated URIs to start a process
# that will fetch the item at the first and return it to the user,
# on failure it will try the second, then third, etc
sub start_reproxy_uri {
    my Perlbal::ClientProxy $self = shift;
    my Perlbal::HTTPHeaders $primary_res_hdrs = shift;
    my $urls = shift;

    # construct reproxy_uri list
    if (defined $urls) {
        my @uris = split /\s+/, $urls;
        $self->{reproxy_uris} = [];
        foreach my $uri (@uris) {
            next unless $uri =~ m!^http://(.+?)(?::(\d+))?(/.*)?$!;
            push @{$self->{reproxy_uris}}, [ $1, $2 || 80, $3 || '/' ];
        }
    }

    # if we have no uris in our list now, tell the user 404
    return $self->_simple_response(404)
        unless @{$self->{reproxy_uris} || []};

    # set the expected size if we got a content length in our headers
    if (my $expected_size = $primary_res_hdrs->header('X-REPROXY-EXPECTED-SIZE')) {
        $self->{reproxy_expected_size} = $expected_size;
    }

    # now build backend
    $self->state('wait_backend');
    my $datref = $self->{reproxy_uris}->[0];
    my $be = Perlbal::BackendHTTP->new(undef, $datref->[0], $datref->[1],
                    { reportto => $self, primary_res_headers => $primary_res_hdrs });
}

# this is a callback for when a backend has been created and is
# ready for us to do something with it
sub register_boredom {
    my Perlbal::ClientProxy $self = shift;
    my Perlbal::BackendHTTP $be = shift;

    # get a URI
    my $datref = shift @{$self->{reproxy_uris}};
    unless (defined $datref) {
        # return 404 and close the backend
        $be->{client} = undef;
        $be->close('invalid_uris');
        return $self->_simple_response(404);
    }

    # now send request
    $self->{backend} = $be;
    $be->{client} = $self;
    my $headers = "GET $datref->[2] HTTP/1.0\r\nConnection: close\r\n\r\n";
    $be->{req_headers} = Perlbal::HTTPHeaders->new(\$headers);
    $be->state('sending_req');
    $self->state('backend_req_sent');
    $be->write($be->{req_headers}->to_string_ref);
    $be->watch_read(1);
    $be->watch_write(1);
}

# this is called when a transient backend getting a reproxied URI has received
# a response from the server and is ready for us to deal with it
sub backend_response_received {
    my Perlbal::ClientProxy $self = shift;
    my Perlbal::BackendHTTP $be = shift;

    # we fail if we got something that's NOT a 2xx code, OR, if we expected
    # a certain size and got back something different
    if ($be->{res_headers}->{code} < 200 || $be->{res_headers}->{code} > 299 ||
            (defined $self->{reproxy_expected_size} &&
             $self->{reproxy_expected_size} != $be->{res_headers}->header('Content-length'))) {
        # fall back to an alternate URL
        $be->{client} = undef;
        $be->close('non_200_reproxy');

        # now call start_reproxy_uri, which, without a second parameter will
        # try the next location in the list we were given originally
        $self->start_reproxy_uri($be->{primary_res_headers});
        return 1;
    }
    return 0;
}

# part of the reportto interface; this is called when a backend is unable to establish
# a connection with a backend.  we simply try the next uri.
sub note_bad_backend_connect {
    my Perlbal::ClientProxy $self = shift;
    my Perlbal::BackendHTTP $be = shift;
    
    # undef the backend's client and setup for the next try
    $be->{client} = undef;
    shift @{$self->{reproxy_uris}};
    $self->start_reproxy_uri($be->{primary_res_headers});
    
    return 1;
}

sub start_reproxy_file {
    my Perlbal::ClientProxy $self = shift;
    my $file = shift;                      # filename to reproxy
    my Perlbal::HTTPHeaders $hd = shift;   # headers from backend, in need of cleanup

    # call hook for pre-reproxy
    return if $self->{service}->run_hook("start_file_reproxy", $self, \$file);

    # set our expected size
    if (my $expected_size = $hd->header('X-REPROXY-EXPECTED-SIZE')) {
        $self->{reproxy_expected_size} = $expected_size;
    }

    # start an async stat on the file
    $self->state('wait_stat');
    Linux::AIO::aio_stat($file, sub {

        # if the client's since disconnected by the time we get the stat,
        # just bail.
        return if $self->{closed};

        my $size = -s _;

        unless ($size) {
            # FIXME: POLICY: 404 or retry request to backend w/o reproxy-file capability?
            return $self->_simple_response(404);
        }
        if (defined $self->{reproxy_expected_size} && $self->{reproxy_expected_size} != $size) {
            # 404; the file size doesn't match what we expected
            return $self->_simple_response(404);
        }
        

        # fixup the Content-Length header with the correct size (application
        # doesn't need to provide a correct value if it doesn't want to stat())
        $hd->header("Content-Length", $size);
        # don't send this internal header to the client:
        $hd->header('X-REPROXY-FILE', undef);

        # rewrite some other parts of the header
        $hd->set_version('1.0');
        $hd->header('Connection', 'close');
        $hd->header('Keep-Alive', undef);

        # just send the header, now that we cleaned it.
        $self->write($hd->to_string_ref);

        if ($self->{req_headers}->request_method eq 'HEAD') {
            $self->write(sub { $self->close('head_request'); });
            return;
        }

        $self->state('wait_open');
        Linux::AIO::aio_open($file, 0, 0 , sub {
            my $rp_fd = shift;

            # if client's gone, just close filehandle and abort
            if ($self->{closed}) {
                POSIX::close($rp_fd) if $rp_fd >= 0;
                return;
            }

            # handle errors
            if ($rp_fd < 0) {
                # FIXME: do 500 vs. 404 vs whatever based on $! ?
                return $self->_simple_response(500);
            }

            $self->reproxy_fd($rp_fd, $size);
            $self->watch_write(1);
        });
    });
}

# Client
# get/set backend proxy connection
sub backend {
    my Perlbal::ClientProxy $self = shift;
    return $self->{backend} unless @_;

    my $backend = shift;
    $self->state('draining_res') unless $backend;
    return $self->{backend} = $backend;
}

# called by the backend when it's done sending us stuff
sub backend_finished {
    my Perlbal::ClientProxy $self = shift;

    # at this point we probably don't actually have a backend anymore.
    # we should definitely mark ourselves as having responded to the
    # user, and close if we have no content length remaining, else
    # we should let the reader close us.
    $self->{responded} = 1;
    $self->close('backend_finished')
        unless defined $self->{content_length_remain} &&
                       $self->{content_length_remain};
}

# Client (overrides and calls super)
sub close {
    my Perlbal::ClientProxy $self = shift;
    my $reason = shift;

    # signal that we're done
    $self->{service}->run_hooks('end_proxy_request', $self);

    # kill our backend if we still have one
    if (my $backend = $self->{backend}) {
        print "Client ($self) closing backend ($backend)\n" if Perlbal::DEBUG >= 1;
        $self->backend(undef);
        $backend->close($reason ? "proxied_from_client_close:$reason" : "proxied_from_client_close");
    } else {
        # if no backend, tell our service that we don't care for one anymore
        $self->{service}->note_client_close($self);
    }

    # call ClientHTTPBase's close
    $self->SUPER::close($reason);
}

# Client
sub event_write {
    my Perlbal::ClientProxy $self = shift;

    $self->SUPER::event_write;

    # obviously if we're writing the backend has processed our request
    # and we are responding/have responded to the user, so mark it so
    $self->{responded} = 1;

    # trigger our backend to keep reading, if it's still connected
    if (my $backend = $self->{backend}) {
        # figure out which maximum buffer size to use
        my $buf_size = defined $backend->{service} ? $self->{service}->{buffer_size} : $self->{service}->{buffer_size_reproxy_url};
        $backend->watch_read(1) if $self->{write_buf_size} < $buf_size;
    }
}

# ClientProxy
sub event_read {
    my Perlbal::ClientProxy $self = shift;

    # mark alive so we don't get killed for being idle
    $self->{alive_time} = time;

    unless ($self->{req_headers}) {
        if (my $hd = $self->read_request_headers) {
            print "Got headers!  Firing off new backend connection.\n"
                if Perlbal::DEBUG >= 2;

            return if $self->{service}->run_hook('start_proxy_request', $self);

            # if defined we're waiting on some amount of data.  also, we have to
            # subtract out read_size, which is the amount of data that was
            # extra in the packet with the header that's part of the body.
            $self->{content_length_remain} = $hd->content_length;
            $self->{content_length_remain} -= $self->{read_size}
                if defined $self->{content_length_remain};

            $self->state('wait_backend');
            $self->{service}->request_backend_connection($self);

            $self->tcp_cork(1);  # cork writes to self
        }
        return;
    }

    # read data and send to backend (or buffer for later sending)
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
        $self->{content_length_remain} -= $len
            if defined $self->{content_length_remain};

        # just dump the read into the nether if we're dangling. that is
        # the case when we send the headers to the backend and it responds
        # before we're done reading from the client; therefore further
        # reads from the client just need to be sent nowhere, because the
        # RFC2616 section 8.2.3 says: "the server SHOULD NOT close the
        # transport connection until it has read the entire request"
        if ($self->{responded}) {
            # in addition, if we're now out of data (clr == 0), then we should
            # close ourselves
            $self->close('responded_done_reading')
                if defined $self->{content_length_remain} &&
                          !$self->{content_length_remain};

            # return since we're done here
            return;
        }

        if ($backend) {
            $backend->write($bref);
        } else {
            push @{$self->{read_buf}}, $bref;
            $self->{read_ahead} += $len;
        }

    } else {
        # our buffer is full, so turn off reads for now
        $self->watch_read(0);
    }
}

sub as_string {
    my Perlbal::ClientProxy $self = shift;

    my $ret = $self->SUPER::as_string;
    if ($self->{backend}) {
        my $ipport = $self->{backend}->{ipport};
        $ret .= "; backend=$ipport";
    } else {
        $ret .= "; write_buf_size=$self->{write_buf_size}"
            if $self->{write_buf_size} > 0;
    }
    $ret .= "; highpri" if $self->{high_priority};
    $ret .= "; responded" if $self->{responded};

    return $ret;
}

sub DESTROY {
    Perlbal::objdtor();
    $_[0]->SUPER::DESTROY;
}

1;


# Local Variables:
# mode: perl
# c-basic-indent: 4
# indent-tabs-mode: nil
# End:
