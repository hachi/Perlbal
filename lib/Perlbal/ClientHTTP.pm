######################################################################
# HTTP Connection from a reverse proxy client.  GET/HEAD only.
#  most functionality is implemented in the base class.
#
# Copyright 2004, Danga Interactice, Inc.
# Copyright 2005, Six Apart, Ltd.
#

package Perlbal::ClientHTTP;
use strict;
use warnings;
no  warnings qw(deprecated);

use base "Perlbal::ClientHTTPBase";

use fields ('put_in_progress', # 1 when we're currently waiting for an async job to return
            'put_fh',          # file handle to use for writing data
            'put_pos',         # file offset to write next data at

            'content_length',  # length of document being transferred
            'content_length_remain', # bytes remaining to be read
            );

use HTTP::Date ();
use File::Path;

use Errno qw( EPIPE );
use POSIX qw( O_CREAT O_TRUNC O_WRONLY O_RDONLY ENOENT );

# class list of directories we know exist
our (%VerifiedDirs);

sub new {
    my $class = shift;

    my $self = fields::new($class);
    $self->SUPER::new(@_);
    $self->init;
    return $self;
}

# upcasting a generic ClientHTTPBase (from a service selector) to a
# "full-fledged" ClientHTTP.
sub new_from_base {
    my $class = shift;
    my Perlbal::ClientHTTPBase $cb = shift;    # base object
    bless $cb, $class;
    $cb->init;

    $cb->watch_read(1);   # enable our reads, so we can get PUT/POST data
    $cb->handle_request;  # this will disable reads, if GET/HEAD/etc
    return $cb;
}

sub init {
    my Perlbal::ClientHTTP $self = shift;
    $self->{put_in_progress} = 0;
    $self->{put_fh} = undef;
    $self->{put_pos} = 0;
}

sub close {
    my Perlbal::ClientHTTP $self = shift;

    # don't close twice
    return if $self->{closed};

    $self->{put_fh} = undef;
    $self->SUPER::close(@_);
}

sub event_read {
    my Perlbal::ClientHTTP $self = shift;

    # see if we have headers?
    if ($self->{req_headers}) {
        if ($self->{req_headers}->request_method eq 'PUT') {
            $self->event_read_put;
        } else {
            # since we have headers and we're not doing any special
            # handling above, let's just disable read notification, because
            # we won't do anything with the data
            $self->watch_read(0);
        }
        return;
    }

    # try and get the headers, if they're all here
    my $hd = $self->read_request_headers
        or return;

    $self->handle_request;
}

# one-time routing of new request to the right handlers
sub handle_request {
    my Perlbal::ClientHTTP $self = shift;
    my $hd = $self->{req_headers};

    # fully formed request received
    $self->{requests}++;

    # notify that we're about to serve
    return if $self->{service}->run_hook('start_web_request',  $self);
    return if $self->{service}->run_hook('start_http_request', $self);

    # GET/HEAD requests (local, from disk)
    if ($hd->request_method eq 'GET' || $hd->request_method eq 'HEAD') {
        # and once we have it, start serving
        $self->watch_read(0);
        return $self->_serve_request($hd);
    }

    # PUT requests
    return $self->handle_put    if $hd->request_method eq 'PUT';

    # DELETE requests
    return $self->handle_delete if $hd->request_method eq 'DELETE';

    # else, bad request
    return $self->send_response(400);
}

sub handle_put {
    my Perlbal::ClientHTTP $self = shift;
    my $hd = $self->{req_headers};

    return $self->send_response(403) unless $self->{service}->{enable_put};

    # they want to put something, so let's setup and wait for more reads
    my $clen =
        $self->{content_length} =
        $self->{content_length_remain} =
        $hd->header('Content-length') + 0;

    # return a 400 (bad request) if we got no content length or if it's
    # bigger than any specified max put size
    return $self->send_response(400, "Content-length of $clen is invalid.")
        if !$clen ||
        ($self->{service}->{max_put_size} &&
         $clen > $self->{service}->{max_put_size});

    # if we have some data already from a header over-read, note it
    if (defined $self->{read_ahead} && $self->{read_ahead} > 0) {
        $self->{content_length_remain} -= $self->{read_ahead};
    }

    return if $self->{service}->run_hook('handle_put', $self);

    # error in filename?  (any .. is an error)
    my $uri = $self->{req_headers}->request_uri;
    return $self->send_response(400, 'Invalid filename')
        if $uri =~ /\.\./;

    # now we want to get the URI
    return $self->send_response(400, 'Invalid filename')
        unless $uri =~ m!^
            ((?:/[\w\-\.]+)*)      # $1: zero+ path components of /FOO where foo is
                                     #   one+ conservative characters
                  /                  # path separator
            ([\w\-\.]+)            # $2: and the filename, one+ conservative characters
            $!x;

    # sanitize uri into path and file into a disk path and filename
    my ($path, $filename) = ($1 || '', $2);

    # the final action we'll be taking, eventually, is to start an async
    # file open of the requested disk path.  but we might need to verify
    # the min_put_directory first.
    my $start_open = sub {
        my $disk_path = $self->{service}->{docroot} . '/' . $path;
        $self->start_put_open($disk_path, $filename);
    };

    # verify minput if necessary
    if ($self->{service}->{min_put_directory}) {
        my @elems = grep { defined $_ && length $_ } split '/', $path;
        return $self->send_response(400, 'Does not meet minimum directory requirement')
            unless scalar(@elems) >= $self->{service}->{min_put_directory};
        my $req_path   = '/' . join('/', splice(@elems, 0, $self->{service}->{min_put_directory}));
        my $extra_path = '/' . join('/', @elems);
        $self->validate_min_put_directory($req_path, $extra_path, $filename, $start_open);
    } else {
        $start_open->();
    }

    return;
}

# called when we're requested to do a delete
sub handle_delete {
    my Perlbal::ClientHTTP $self = shift;

    return $self->send_response(403) unless $self->{service}->{enable_delete};

    $self->watch_read(0);

    # error in filename?  (any .. is an error)
    my $uri = $self->{req_headers}->request_uri;
    return $self->send_response(400, 'Invalid filename')
        if $uri =~ /\.\./;

    # now we want to get the URI
    if ($uri =~ m!^(?:/[\w\-\.]+)+$!) {
        # now attempt the unlink
        Perlbal::AIO::aio_unlink($self->{service}->{docroot} . '/' . $uri, sub {
            my $err = shift;
            if ($err == 0 && !$!) {
                # delete was successful
                return $self->send_response(204);
            } elsif ($! == ENOENT) {
                # no such file
                return $self->send_response(404);
            } else {
                # failure...
                return $self->send_response(400, "$!");
            }
        });
    } else {
        # bad URI, don't accept the delete
        return $self->send_response(400, 'Invalid filename');
    }
}

sub event_read_put {
    my Perlbal::ClientHTTP $self = shift;

    # read in data and shove it on the read buffer
    my $dataref = $self->read($self->{content_length_remain});

    # unless they disconnected prematurely
    unless (defined $dataref) {
        $self->close('remote_closure');
        return;
    }

    # got some data
    push @{$self->{read_buf}}, $dataref;
    my $clen = length($$dataref);
    $self->{read_size}  += $clen;
    $self->{read_ahead} += $clen;
    $self->{content_length_remain} -= $clen;

    if ($self->{content_length_remain}) {
        $self->put_writeout if $self->{read_ahead} >= 8192; # arbitrary
    } else {
        # now, if we've filled the content of this put, we're done
        $self->watch_read(0);
        $self->put_writeout;
    }
}

# verify that a minimum put directory exists.  if/when it's verified,
# perhaps cached, the provided callback will be run.
sub validate_min_put_directory {
    my Perlbal::ClientHTTP $self = shift;
    my ($req_path, $extra_path, $filename, $callback) = @_;

    my $disk_dir = $self->{service}->{docroot} . '/' . $req_path;
    return $callback->() if $VerifiedDirs{$disk_dir};

    $self->{put_in_progress} = 1;

    Perlbal::AIO::aio_open($disk_dir, O_RDONLY, 0755, sub {
        my $fh = shift;
        $self->{put_in_progress} = 0;

        # if error return failure
        return $self->send_response(404, "Base directory does not exist") unless $fh;
        CORE::close($fh);

        # mindir existed, mark it as so and start the open for the rest of the path
        $VerifiedDirs{$disk_dir} = 1;
        $callback->();
    });
}

# attempt to open a file being PUT for writing to disk
sub start_put_open {
    my Perlbal::ClientHTTP $self = shift;
    my ($path, $file) = @_;

    $self->{put_in_progress} = 1;

    Perlbal::AIO::aio_open("$path/$file", O_CREAT | O_TRUNC | O_WRONLY, 0644, sub {
        # get the fd
        my $fh = shift;

        # verify file was opened
        $self->{put_in_progress} = 0;

        if (! $fh) {
            if ($! == ENOENT) {
                # directory doesn't exist, so let's manually create it
                eval { File::Path::mkpath($path, 0, 0755); };
                return $self->system_error("Unable to create directory", "path = $path, file = $file") if $@;

                # should be created, call self recursively to try
                return $self->start_put_open($path, $file);
            } else {
                return $self->system_error("Internal error", "error = $!, path = $path, file = $file");
            }
        }

        $self->{put_fh} = $fh;
        $self->{put_pos} = 0;
        $self->put_writeout;
    });
}

# called when we've got some put data to write out
sub put_writeout {
    my Perlbal::ClientHTTP $self = shift;
    Carp::confess("wrong class for $self") unless ref $self eq "Perlbal::ClientHTTP";

    return if $self->{service}->run_hook('put_writeout', $self);
    return if $self->{put_in_progress};
    return unless $self->{put_fh};
    return unless $self->{read_ahead};

    my $data = join("", map { $$_ } @{$self->{read_buf}});
    my $count = length $data;

    # reset our input buffer
    $self->{read_buf}   = [];
    $self->{read_ahead} = 0;

    # okay, file is open, write some data
    $self->{put_in_progress} = 1;

    Perlbal::AIO::aio_write($self->{put_fh}, $self->{put_pos}, $count, $data, sub {
        return if $self->{closed};

        # see how many bytes written
        my $bytes = shift() + 0;

        $self->{put_pos} += $bytes;
        $self->{put_in_progress} = 0;

        # now recursively call ourselves?
        if ($self->{read_ahead}) {
            $self->put_writeout;
            return;
        }

        return if $self->{content_length_remain};

        # we're done putting this file, so close it.
        # FIXME this should be done through AIO
        if ($self->{put_fh} && CORE::close($self->{put_fh})) {
            $self->{put_fh} = undef;
            return $self->send_response(200);
        } else {
            return $self->system_error("Error saving file", "error in close: $!");
        }
    });
}

1;

# Local Variables:
# mode: perl
# c-basic-indent: 4
# indent-tabs-mode: nil
# End:
