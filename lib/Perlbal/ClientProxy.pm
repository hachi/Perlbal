######################################################################
# HTTP Connection from a reverse proxy client
#
# Copyright 2004, Danga Interactice, Inc.
# Copyright 2005, Six Apart, Ltd.
#
package Perlbal::ClientProxy;
use strict;
use warnings;
use base "Perlbal::ClientHTTPBase";
use fields (
            'backend',             # Perlbal::BackendHTTP object (or undef if disconnected)
            'backend_requested',   # true if we've requested a backend for this request
            'reconnect_count',     # number of times we've tried to reconnect to backend
            'high_priority',       # boolean; 1 if we are or were in the high priority queue
            'reproxy_uris',        # arrayref; URIs to reproxy to, in order
            'reproxy_expected_size', # int: size of response we expect to get back for reproxy
            'currently_reproxying',  # arrayref; the host info and URI we're reproxying right now
            'content_length_remain', # int: amount of data we're still waiting for
            'responded',           # bool: whether we've already sent a response to the user or not
            'last_request_time',   # int: time that we last received a request
            'primary_res_hdrs',  # if defined, we are doing a transparent reproxy-URI
                                 # and the headers we get back aren't necessarily
                                 # the ones we want.  instead, get most headers
                                 # from the provided res headers object here.
            );

use constant READ_SIZE         => 4096;    # 4k, arbitrary
use constant READ_AHEAD_SIZE   => 8192;    # 8k, arbitrary
use Errno qw( EPIPE );
use POSIX ();

# ClientProxy
sub new {
    my ($class, $service, $sock) = @_;

    my $self = $class;
    $self = fields::new($class) unless ref $self;
    $self->SUPER::new($service, $sock);       # init base fields

    Perlbal::objctor($self);
    bless $self, ref $class || $class;

    $self->init;
    $self->watch_read(1);
    return $self;
}

sub new_from_base {
    my $class = shift;
    my Perlbal::ClientHTTPBase $cb = shift;
    bless $cb, $class;
    $cb->init;
    $cb->event_read($cb->{req_headers});  # see comments in event_read: we're jumping into the middle of the process
    return $cb;
}

sub init {
    my Perlbal::ClientProxy $self = $_[0];

    $self->{last_request_time} = 0;

    $self->{backend} = undef;
    $self->{high_priority} = 0;

    $self->{responded} = 0;
    $self->{content_length_remain} = undef;
    $self->{backend_requested} = 0;

    $self->{reproxy_uris} = undef;
    $self->{reproxy_expected_size} = undef;
    $self->{currently_reproxying} = undef;
}

# call this with a string of space separated URIs to start a process
# that will fetch the item at the first and return it to the user,
# on failure it will try the second, then third, etc
sub start_reproxy_uri {
    my Perlbal::ClientProxy $self = $_[0];
    my Perlbal::HTTPHeaders $primary_res_hdrs = $_[1];
    my $urls = $_[2];

    # at this point we need to disconnect from our backend
    $self->{backend} = undef;

    # failure if we have no primary response headers
    return unless $self->{primary_res_hdrs} ||= $primary_res_hdrs;

    # construct reproxy_uri list
    if (defined $urls) {
        my @uris = split /\s+/, $urls;
        $self->{currently_reproxying} = undef;
        $self->{reproxy_uris} = [];
        foreach my $uri (@uris) {
            next unless $uri =~ m!^http://(.+?)(?::(\d+))?(/.*)?$!;
            push @{$self->{reproxy_uris}}, [ $1, $2 || 80, $3 || '/' ];
        }
    }

    # if we get in here and we have currently_reproxying defined, then something
    # happened and we want to retry that one
    if ($self->{currently_reproxying}) {
        unshift @{$self->{reproxy_uris}}, $self->{currently_reproxying};
        $self->{currently_reproxying} = undef;
    }

    # if we have no uris in our list now, tell the user 404
    return $self->_simple_response(503)
        unless @{$self->{reproxy_uris} || []};

    # set the expected size if we got a content length in our headers
    if ($primary_res_hdrs && (my $expected_size = $primary_res_hdrs->header('X-REPROXY-EXPECTED-SIZE'))) {
        $self->{reproxy_expected_size} = $expected_size;
    }

    # pass ourselves off to the reproxy manager
    $self->state('wait_backend');
    Perlbal::ReproxyManager::do_reproxy($self);
}

# called by the reproxy manager when we can't get to our requested backend
sub try_next_uri {
    my Perlbal::ClientProxy $self = $_[0];

    shift @{$self->{reproxy_uris}};
    $self->{currently_reproxying} = undef;
    $self->start_reproxy_uri();
}

# this is a callback for when a backend has been created and is
# ready for us to do something with it
sub use_reproxy_backend {
    my Perlbal::ClientProxy $self = $_[0];
    my Perlbal::BackendHTTP $be = $_[1];

    # get a URI
    my $datref = $self->{currently_reproxying} = shift @{$self->{reproxy_uris}};
    unless (defined $datref) {
        # return error and close the backend
        $be->close('invalid_uris');
        return $self->_simple_response(503);
    }

    # now send request
    $self->{backend} = $be;
    $be->{client} = $self;

    my $extra_hdr = "";
    if (my $range = $self->{req_headers}->header("Range")) {
        $extra_hdr .= "Range: $range\r\n";
    }

    my $headers = "GET $datref->[2] HTTP/1.0\r\nConnection: keep-alive\r\n${extra_hdr}\r\n";

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
    my Perlbal::ClientProxy $self = $_[0];
    my Perlbal::BackendHTTP $be = $_[1];

    # a response means that we are no longer currently waiting on a reproxy, and
    # don't want to retry this URI
    $self->{currently_reproxying} = undef;

    # we fail if we got something that's NOT a 2xx code, OR, if we expected
    # a certain size and got back something different
    my $code = $be->{res_headers}->response_code + 0;

    my $bad_code = sub {
        return 0 if $code >= 200 && $code <= 299;
        return 0 if $code == 416;
        return 1;
    };

    my $bad_size = sub {
        return 0 unless defined $self->{reproxy_expected_size};
        return $self->{reproxy_expected_size} != $be->{res_headers}->header('Content-length');
    };

    if ($bad_code->() || $bad_size->()) {
        # fall back to an alternate URL
        $be->{client} = undef;
        $be->close('non_200_reproxy');
        $self->try_next_uri;
        return 1;
    }
    return 0;
}

sub start_reproxy_file {
    my Perlbal::ClientProxy $self = shift;
    my $file = shift;                      # filename to reproxy
    my Perlbal::HTTPHeaders $hd = shift;   # headers from backend, in need of cleanup

    # at this point we need to disconnect from our backend
    $self->{backend} = undef;

    # call hook for pre-reproxy
    return if $self->{service}->run_hook("start_file_reproxy", $self, \$file);

    # set our expected size
    if (my $expected_size = $hd->header('X-REPROXY-EXPECTED-SIZE')) {
        $self->{reproxy_expected_size} = $expected_size;
    }

    # start an async stat on the file
    $self->state('wait_stat');
    Perlbal::AIO::aio_stat($file, sub {

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

        # if the thing we're reproxying is indeed a file, advertise that
        # we support byteranges on it
        if (-f _) {
            $hd->header("Accept-Ranges", "bytes");
        }

        my ($status, $range_start, $range_end) = $self->{req_headers}->range($size);
        my $not_satisfiable = 0;

        if ($status == 416) {
            $hd = Perlbal::HTTPHeaders->new_response(416);
            $hd->header("Content-Range", $size ? "bytes */$size" : "*");
            $not_satisfiable = 1;
        }

        # change the status code to 200 if the backend gave us 204 No Content
        $hd->code(200) if $hd->response_code == 204;

        # fixup the Content-Length header with the correct size (application
        # doesn't need to provide a correct value if it doesn't want to stat())
        if ($status == 200) {
            $hd->header("Content-Length", $size);
        } elsif ($status == 206) {
            $hd->header("Content-Range", "bytes $range_start-$range_end/$size");
            $hd->header("Content-Length", $range_end - $range_start + 1);
            $hd->code(206);
        }

        # don't send this internal header to the client:
        $hd->header('X-REPROXY-FILE', undef);

        # rewrite some other parts of the header
        $self->setup_keepalive($hd);

        # just send the header, now that we cleaned it.
        $self->{res_headers} = $hd;
        $self->write($hd->to_string_ref);

        if ($self->{req_headers}->request_method eq 'HEAD' || $not_satisfiable) {
            $self->write(sub { $self->http_response_sent; });
            return;
        }

        $self->state('wait_open');
        Perlbal::AIO::aio_open($file, 0, 0 , sub {
            my $fh = shift;

            # if client's gone, just close filehandle and abort
            if ($self->{closed}) {
                CORE::close($fh) if $fh;
                return;
            }

            # handle errors
            if (! $fh) {
                # FIXME: do 500 vs. 404 vs whatever based on $! ?
                return $self->_simple_response(500);
            }

            # seek if partial content
            if ($status == 206) {
                sysseek($fh, $range_start, &POSIX::SEEK_SET);
                $size = $range_end - $range_start + 1;
            }

            $self->reproxy_fh($fh, $size);
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

# our backend enqueues a call to this method in our write buffer, so this is called
# right after we've finished sending all of the results to the user.  at this point,
# if we were doing keep-alive, we don't close and setup for the next request.
sub backend_finished {
    my Perlbal::ClientProxy $self = shift;

    # mark ourselves as having responded (presumeably if we're here,
    # the backend has responded already)
    $self->{responded} = 1;

    # our backend is done with us, so we disconnect ourselves from it
    $self->{backend} = undef;

    # now, two cases; undefined clr, or defined and zero, or defined and non-zero
    if (defined $self->{content_length_remain}) {
        # defined, so a POST, close if it's 0 or less
        return $self->http_response_sent
            if $self->{content_length_remain} <= 0;
    } else {
        # not defined, so we're ready for another connection?
        return $self->http_response_sent;
    }
}

# called when we've sent a response to a user fully and we need to reset state
sub http_response_sent {
    my Perlbal::ClientProxy $self = $_[0];

    # persistence logic is in ClientHTTPBase
    return 0 unless $self->SUPER::http_response_sent;

    # if we get here we're being persistent, reset our state
    $self->{backend_requested} = 0;
    $self->{backend} = undef;
    $self->{high_priority} = 0;
    $self->{reproxy_uris} = undef;
    $self->{reproxy_expected_size} = undef;
    $self->{currently_reproxying} = undef;
    $self->{content_length_remain} = undef;
    $self->{primary_res_hdrs} = undef;
    $self->{responded} = 0;
    return 1;
}

# Client (overrides and calls super)
sub close {
    my Perlbal::ClientProxy $self = shift;
    my $reason = shift;

    # don't close twice
    return if $self->{closed};

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

    my $base_headers = shift;  # not from Danga::Socket:  if new_from_base calls us, it gives us the headers to assume we just read

    # mark alive so we don't get killed for being idle
    $self->{alive_time} = time;

    # used a few times below to trigger the send start
    my $request_backend = sub {
        return if $self->{backend_requested};
        $self->{backend_requested} = 1;

        $self->state('wait_backend');
        $self->{service}->request_backend_connection($self);
        $self->tcp_cork(1);  # cork writes to self
    };

    if (! $self->{req_headers} || $base_headers) {

        if (my $hd = ($base_headers || $self->read_request_headers)) {
            print "Got headers!  Firing off new backend connection.\n"
                if Perlbal::DEBUG >= 2;

            return if $self->{service}->run_hook('start_proxy_request', $self);
            return if $self->{service}->run_hook('start_http_request',  $self);

            # if defined we're waiting on some amount of data.  also, we have to
            # subtract out read_size, which is the amount of data that was
            # extra in the packet with the header that's part of the body.
            $self->{content_length_remain} = $hd->content_length;
            $self->{content_length_remain} -= $self->{read_size}
                if defined $self->{content_length_remain};

            # note that we've gotten a request
            $self->{requests}++;
            $self->{last_request_time} = $self->{alive_time};

            # request a backend, or start buffering
            if ($self->{service}->{buffer_backend_connect} && $self->{content_length_remain}) {
                # buffer logic; note we don't do anything here except set our state and move on
                $self->state('buffering_request');
            } else {
                # dispatch to backend
                $request_backend->();
            }
        }
        return;
    }

    # read data and send to backend (or buffer for later sending)
    if ($self->{read_ahead} < ($self->{service}->{buffer_backend_connect} || READ_AHEAD_SIZE)) {
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
            # either close ourselves or get ready for another request
            return $self->http_response_sent
                if defined $self->{content_length_remain} &&
                          ($self->{content_length_remain} <= 0);

            # at this point, if the backend has responded then we just return
            # as we don't want to send it on to them or buffer it up, which is
            # what the code below does
            return;
        }

        if ($backend) {
            $backend->write($bref);
        } else {
            push @{$self->{read_buf}}, $bref;
            $self->{read_ahead} += $len;

            # this is when we have read all their data
            $request_backend->()
                if defined $self->{content_length_remain} &&
                           $self->{content_length_remain} <= 0;
        }

    } else {
        # our buffer is full, so turn off reads for now
        $self->watch_read(0);

        # we've exceeded our buffer_backend_connect, start getting a backend for us
        $request_backend->();
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
    $ret .= "; waiting_for=" . $self->{content_length_remain}
        if defined $self->{content_length_remain};
    $ret .= "; reproxying" if $self->{currently_reproxying};

    return $ret;
}

sub DESTROY {
    Perlbal::objdtor($_[0]);
    $_[0]->SUPER::DESTROY;
}

1;


# Local Variables:
# mode: perl
# c-basic-indent: 4
# indent-tabs-mode: nil
# End:
