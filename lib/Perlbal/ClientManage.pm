######################################################################
# Management connection from a client
######################################################################

package Perlbal::ClientManage;
use strict;
use base "Perlbal::Socket";
use fields ('service',
            'buf',
            'is_http',  # bool: is an HTTP request?
            );  

# ClientManage
sub new {
    my ($class, $service, $sock) = @_;
    my $self = $class->SUPER::new($sock);
    $self->{service} = $service;
    $self->{buf} = "";   # what we've read so far, not forming a complete line
    bless $self, ref $class || $class;
    $self->watch_read(1);
    return $self;
}

# ClientManage
sub event_read {
    my Perlbal::ClientManage $self = shift;

    my $bref;
    unless ($self->{is_http}) {
        $bref = $self->read(1024);
        return $self->close() unless defined $bref;
        $self->{buf} .= $$bref;

        if ($self->{buf} =~ /^(?:HEAD|GET|POST) /) {
            $self->{is_http} = 1;
            $self->{headers_string} .= $$bref;
        }
    }

    if ($self->{is_http}) {
        my $hd = $self->read_request_headers;
        return unless $hd;
        $self->handle_http();
        return;
    }

    if ($self->{buf} =~ s/^(.+?)\r?\n//) {
        my $line = $1;
        Perlbal::run_manage_command($line, sub {
            $self->write("$_[0]\r\n");
        });
    }
}

# ClientManage
sub event_err {  my $self = shift; $self->close; }
sub event_hup {  my $self = shift; $self->close; }

# HTTP management support
sub handle_http {
    my Perlbal::ClientManage $self = shift;

    my $uri = $self->{headers}->request_uri;

    my $body;
    my $code = "200 OK";

    if ($uri eq "/") {
        $body .= "<h1>perlbal management interface</h1>";
        $body .= "<a href='/stats'>Server Stats</a>";
    } elsif ($uri eq "/stats") {
        my $sf = Perlbal::Socket->get_sock_ref;
        $body .= "<table border='1' cellpadding='2'>";
        $body .= "<tr><th>fd</th><th>age</th><th>description</th></tr>\n";
        my $now = time;
        foreach (sort { $a <=> $b } keys %$sf) {
            my $sock = $sf->{$_};
            my $age = $now - $sock->{create_time};
            $body .= "<tr><td>$_</td><td>$age</td><td>" . $sock->as_string_html . "</td></tr>\n";
        }
        $body .= "</table>";
    } else {
        $code = "404 Not found";
        $body .= "<h1>$code</h1>";
    }

    $body .= "<hr />Go to <a href='/'>top-level</a>.\n";
    $self->write("HTTP/1.0 $code\r\nContent-type: text/html\r\nContent-Length: " . length($body) . 
                 "\r\n\r\n$body");
    $self->write(sub { $self->close; });
    return;
}

1;


# Local Variables:
# mode: perl
# c-basic-indent: 4
# indent-tabs-mode: nil
# End:
