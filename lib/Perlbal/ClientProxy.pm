######################################################################
# HTTP Connection from a reverse proxy client
######################################################################

package Perlbal::ClientProxy;
use strict;
use base "Perlbal::ClientHTTPBase";
use fields (
            'backend',             # Perlbal::BackendHTTP object (or undef if disconnected)
            'reconnect_count',     # number of times we've tried to reconnect to backend
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
            return $self->_simple_response(404);
        }

        # fixup the Content-Length header with the correct size (application
        # doesn't need to provide a correct value if it doesn't want to stat())
        $hd->header("Content-Length", $size);
        # don't send this internal header to the client:
        $hd->header('X-REPROXY-FILE', undef);

        # just send the header, now that we cleaned it.
        $self->write($hd->to_string_ref);

        if ($self->{headers}->request_method eq 'HEAD') {
            $self->write(sub { $self->close; });
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
    return $self->{backend} = shift;
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

    # trigger our backend to keep reading, if it's still connected
    my $backend = $self->{backend};
    $backend->watch_read(1) if $backend;
}

# ClientProxy
sub event_read {
    my Perlbal::ClientProxy $self = shift;

    unless ($self->{headers}) {
        if (my $hd = $self->read_request_headers) {
            print "Got headers!  Firing off new backend connection.\n"
                if Perlbal::DEBUG >= 2;

            $self->{service}->request_backend_connection($self);

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
