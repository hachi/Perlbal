######################################################################
# Common HTTP functionality for ClientProxy and ClientHTTP
# possible states: 
#   reading_headers (initial state, then follows one of two paths)
#     wait_backend, backend_req_sent, wait_res, xfer_res
#     wait_stat, wait_open, xfer_disk
######################################################################

package Perlbal::ClientHTTPBase;
use strict;
use base "Perlbal::Socket";
use HTTP::Date ();
use fields ('service',             # Perlbal::Service object

            # reproxy support
            'reproxy_file',        # filename the backend told us to start opening
            'reproxy_file_size',   # size of file, once we stat() it
            'reproxy_fd',          # integer fd of reproxying file, once we open() it
            'reproxy_file_offset', # how much we've sent from the file.
            );

use Errno qw( EPIPE ECONNRESET );
use POSIX ();

# ghetto hard-coding.  should let siteadmin define or something.
# maybe console/config command:  AddMime <ext> <mime-type>  (apache-style?)
our $MimeType = {qw(
                    css  text/css
                    doc  application/msword
                    gif  image/gif
                    htm  text/html
                    html text/html
                    jpg  image/jpeg
                    js   application/x-javascript
                    mp3  audio/mpeg
                    mpg  video/mpeg
                    png  image/png
                    tif   image/tiff
                    tiff  image/tiff
                    torrent  application/x-bittorrent
                    txt   text/plain
                    zip   application/zip
)};

# ClientHTTPBase
sub new {
    my ($class, $service, $sock) = @_;

    my $self = $class;
    $self = fields::new($class) unless ref $self;
    $self->SUPER::new($sock);       # init base fields

    $self->{service} = $service;
    $self->{headers_string} = '';
    $self->{state} = 'reading_headers';

    bless $self, ref $class || $class;
    $self->watch_read(1);
    return $self;
}


sub headers {
    my Perlbal::ClientHTTPBase $self = shift;
    return $self->{headers} unless @_;
    return $self->{headers} = shift;
}

sub close {
    my Perlbal::ClientHTTPBase $self = shift;
    my $reason = shift;

    # close the file we were reproxying, if any
    POSIX::close($self->{reproxy_fd}) if $self->{reproxy_fd};

    $self->SUPER::close($reason);
}

sub reproxy_fd {
    my Perlbal::ClientHTTPBase $self = shift;
    return $self->{reproxy_fd} unless @_;

    my ($fd, $size) = @_;
    $self->{state} = 'xfer_disk';
    $self->{reproxy_file_offset} = 0;
    $self->{reproxy_file_size} = $size;
    return $self->{reproxy_fd} = $fd;
}

sub event_write {
    my Perlbal::ClientHTTPBase $self = shift;

    # Any HTTP client is considered alive if it's writable
    # if it's not writable for 30 seconds, we kill it.
    # subclasses can decide what's appropriate for timeout.
    $self->{alive_time} = time;

    if ($self->{reproxy_fd}) {
        my $to_send = $self->{reproxy_file_size} - $self->{reproxy_file_offset};
        $self->tcp_cork(1) if $self->{reproxy_file_offset} == 0;
        my $sent = IO::SendFile::sendfile($self->{fd},
                                          $self->{reproxy_fd},
                                          0, # NULL offset means kernel moves filepos (apparently)
                                          $to_send);
        print "REPROXY Sent: $sent\n" if Perlbal::DEBUG >= 2;
        if ($sent < 0) {
            return $self->close("epipe") if $! == EPIPE;
            return $self->close("connreset") if $! == ECONNRESET;
            print STDERR "Error w/ sendfile: $!\n";
            $self->close;
            return;
        }
        $self->{reproxy_file_offset} += $sent;

        if ($sent >= $to_send) {
            # close the sendfile fd
            my $rv = POSIX::close($self->{reproxy_fd});
            
            $self->{reproxy_fd} = undef;
            $self->close("sendfile_done");
        }
        return;
    }

    if ($self->write(undef)) {
        print "All writing done to $self\n" if Perlbal::DEBUG >= 2;

        # we've written all data in the queue, so stop waiting for write
        # notifications:
        $self->watch_write(0);
    }
}

# this gets called when a "web" service is serving a file locally.
sub _serve_request {
    my Perlbal::ClientHTTPBase $self = shift;
    my Perlbal::HTTPHeaders $hd = shift;

    my $rm = $hd->request_method;
    unless ($rm eq "HEAD" || $rm eq "GET") {
        return $self->_simple_response(403, "Unimplemented method");
    }

    my $uri = _durl($hd->request_uri);

    # don't allow directory traversal
    if ($uri =~ /\.\./ || $uri !~ m!^/!) {
        return $self->_simple_response(403, "Bogus URL");
    }

    my Perlbal::Service $svc = $self->{service};
    my $file = $svc->{docroot} . $uri;

    # update state, since we're now waiting on stat
    $self->{state} = 'wait_stat';
    
    Linux::AIO::aio_stat($file, sub {
        # client's gone anyway
        return if $self->{closed};
        return $self->_simple_response(404) unless -e _;

        my $lastmod = HTTP::Date::time2str((stat(_))[9]);
        my $not_mod = ($hd->header("If-Modified-Since") || "") eq $lastmod;

        my $res = Perlbal::HTTPHeaders->new_response($not_mod ? 304 : 200);

        $res->header("Connection", "close");
        $res->header("Date", HTTP::Date::time2str());
        $res->header("Server", "Perlbal");
        $res->header("Last-Modified", $lastmod);

        if (-f _) {
            my $size = -s _;
            my ($ext) = ($file =~ /\.(\w+)$/);
            $res->header("Content-Type",
                         (defined $ext && exists $MimeType->{$ext}) ? $MimeType->{$ext} : "text/plain");
            $res->header("Content-Length", $size);

            if ($rm eq "HEAD" || $not_mod) {
                # we can return already, since we know the size
                $self->tcp_cork(1);
                $self->write($res->to_string_ref);
                $self->write(sub { $self->close; });
                return;
            }

            # state update
            $self->{state} = 'wait_open';
            
            Linux::AIO::aio_open($file, 0, 0, sub {
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

                $self->{state} = 'xfer_disk';
                $self->tcp_cork(1);  # cork writes to self
                $self->write($res->to_string_ref);
                $self->reproxy_fd($rp_fd, $size);
                $self->watch_write(1);
            });

        } elsif (-d _) {
            my $body;

            if ($svc->{dirindexing}) {
                $res->header("Content-Type", "text/html");
                opendir(D, $file);
                foreach my $de (sort readdir(D)) {
                    if (-d "$file/$de") {
                        $body .= "<b><a href='$de/'>$de</a></b><br />\n";
                    } else {
                        $body .= "<a href='$de'>$de</a><br />\n";
                    }
                }
                closedir(D);
            } else {
                $res->header("Content-Type", "text/html");
                $body = "Directory listing disabled";
            }

            $res->header("Content-Length", length($body));

            $self->{state} = 'xfer_resp';
            $self->tcp_cork(1);  # cork writes to self
            $self->write($res->to_string_ref);
            $self->write(\$body);
            $self->write(sub { $self->close; });
        }
    });
    
    
}

sub _simple_response {
    my Perlbal::ClientHTTPBase $self = shift;
    my ($code, $msg) = @_;  # or bodyref

    my $res = Perlbal::HTTPHeaders->new_response($code);
    $res->header("Content-Type", "text/html");

    my $en = $res->http_code_english;
    my $body = "<h1>$code" . ($en ? " - $en" : "") . "</h1>\n";
    $body .= $msg if $msg;

    $self->{state} = 'xfer_resp';
    $self->tcp_cork(1);  # cork writes to self
    $self->write($res->to_string_ref);
    $self->write(\$body);
    $self->write(sub { $self->close; });
    return 1;
}

# FIXME: let this be configurable?
sub max_idle_time { 30; }

sub event_err {  my $self = shift; $self->close; }
sub event_hup {  my $self = shift; $self->close; }

sub as_string {
    my Perlbal::ClientHTTPBase $self = shift;

    my $name = getsockname($self->{sock});
    my $lport = $name ? (Socket::sockaddr_in($name))[0] : undef;
    my $ret = $self->SUPER::as_string . ": localport=$lport";
    $ret .= "; $self->{state}";

    my $hd = $self->headers;
    if (defined $hd) {
        my $host = $hd->header('Host') || 'unknown';
        $ret .= "; http://$host" . $hd->request_uri;
    }

    return $ret;
}

sub _durl {
    my ($a) = @_;
    $a =~ tr/+/ /;
    $a =~ s/%([a-fA-F0-9][a-fA-F0-9])/pack("C", hex($1))/eg;
    return $a;
}

1;


# Local Variables:
# mode: perl
# c-basic-indent: 4
# indent-tabs-mode: nil
# End:
