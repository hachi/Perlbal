######################################################################
# HTTP connection to backend node
######################################################################

package Perlbal::BackendHTTP;
use strict;
use base "Perlbal::Socket";
use fields qw(client service ip port ipport);
use Socket qw(PF_INET IPPROTO_TCP SOCK_STREAM);

use Perlbal::ClientProxy;

# if this is made too big, (say, 128k), then perl does malloc instead
# of using its slab cache.
use constant BACKEND_READ_SIZE => 61449;  # 60k, to fit in a 64k slab

# constructor for a backend connection takes a service (pool) that it's
# for, and uses that service to get its backend IP/port, as well as the
# client that will be using this backend connection.
sub new {
    my ($class, $svc, $ip, $port) = @_;

    my $sock;
    socket $sock, PF_INET, SOCK_STREAM, IPPROTO_TCP;

    unless ($sock && defined fileno($sock)) {
        print STDERR "Error creating socket: $!\n";
        return undef;
    }

    IO::Handle::blocking($sock, 0);
    connect $sock, Socket::sockaddr_in($port, Socket::inet_aton($ip));

    my $self = fields::new($class);
    $self->SUPER::new($sock);

    Perlbal::objctor();

    $self->{ip}      = $ip;       # backend IP
    $self->{port}    = $port;     # backend port
    $self->{ipport}  = "$ip:$port";  # often used as key
    $self->{service} = $svc;      # the service we're serving for

    # for header reading:
    $self->{headers} = undef;      # defined w/ headers object once all headers in
    $self->{headers_string} = "";  # blank to start
    $self->{read_buf} = [];        # scalar refs of bufs read from client
    $self->{read_ahead} = 0;       # bytes sitting in read_buf
    $self->{read_size} = 0;        # total bytes read from client

    $self->{client}   = undef;     # Perlbal::ClientProxy object, initially empty 
                                   #    until we ask our service for one

    bless $self, ref $class || $class;
    $self->watch_write(1);
    return $self;
}

sub close {
    my Perlbal::BackendHTTP $self = shift;
    my $reason = shift;

    # tell our client that we're gone
    if (my $client = $self->{client}) {
        $client->backend(undef);
    }

    $self->SUPER::close($reason);
}

# called by service when it's got a client for us, or by ourselves
# when we asked for a client.
# returns true if client assignment was accepted.
sub assign_client {
    my Perlbal::BackendHTTP $self = shift;
    my Perlbal::ClientProxy $client = shift;
    return 0 if $self->{client};

    # set our client, and the client's backend to us
    $client->{service}->mark_node_used($self->{ipport});
    $self->{client} = $client;   
    $self->{client}->backend($self);

    my $hds = $client->headers;

    $hds->header("Connection", "close");

    # FIXME: make this conditional
    $hds->header("X-Proxy-Capabilities", "reproxy-file");
    $hds->header("X-Forwarded-For", $client->peer_addr_string);
    $hds->header("X-Host", undef);
    $hds->header("X-Forwarded-Host", undef);

    $self->tcp_cork(1);
    $self->write($hds->to_string_ref);
    $self->write(sub {
        $self->tcp_cork(0);
        if (my $client = $self->{client}) {
            # start waiting on a reply
            $self->watch_read(1);
            # make the client push its overflow reads (request body)
            # to the backend
            $client->drain_read_buf_to($self);
            # and start watching for more reads
            $client->watch_read(1);
        }
    });

    return 1;
}

# Backend
sub event_write {
    my Perlbal::BackendHTTP $self = shift;
    print "Backend $self is writeable!\n" if Perlbal::DEBUG >= 2;

    unless ($self->{client}) {
        $self->{service}->register_boredom($self);
        $self->watch_write(0);
        return;
    }

    my $done = $self->write(undef);
    $self->watch_write(0) if $done;
}

# Backend
sub event_read {
    my Perlbal::BackendHTTP $self = shift;
    print "Backend $self is readable!\n" if Perlbal::DEBUG >= 2;

    my Perlbal::ClientProxy $client = $self->{client};

    unless ($self->{headers}) {
        if (my $hd = $self->read_response_headers) {

            if (my $rep = $hd->header('X-REPROXY-FILE')) {
                # make the client begin the async IO and reproxy
                # process while we detach and die
                $client->start_reproxy_file($rep, $hd);
                $client->backend(undef);    # disconnect ourselves from it

                $self->{client} = undef;    # .. and it from us
                $self->close;               # close ourselves
                return;
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

        $client->write(sub { $client->close() });
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

    if ($self->{client}) {
        # request already sent to backend, then an error occurred.
        # we don't want to duplicate POST requests, so for now
        # just fail
        # TODO: if just a GET request, retry?
        $self->{client}->close;
        $self->close;
        return;
    }

    # close ourselves first
    $self->close("error");

    # then tell the service manager that this connection
    # failed, so it can spawn a new one and note the dead host
    $self->{service}->note_bad_backend_connect($self->{ip}, $self->{port});
}

# Backend
sub event_hup {
    my Perlbal::BackendHTTP $self = shift;
    print "HANGUP for $self\n" if Perlbal::DEBUG;
}

sub as_string {
    my Perlbal::BackendHTTP $self = shift;

    my $name = getsockname($self->{sock});
    my $lport = $name ? (Socket::sockaddr_in($name))[0] : undef;
    my $ret = $self->SUPER::as_string . ": localport=$lport";
    if (my Perlbal::ClientProxy $cp = $self->{client}) {
        $ret .= "; client=$cp->{fd}";
    } elsif ($self->peer_addr_string) {
        $ret .= "; bored";
    } else {
        $ret .= "; connecting";
    }

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
