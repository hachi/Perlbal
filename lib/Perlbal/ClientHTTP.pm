######################################################################
# HTTP Connection from a reverse proxy client.  GET/HEAD only.
#  most functionality is implemented in the base class.
######################################################################

package Perlbal::ClientHTTP;
use strict;
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
use POSIX qw( O_CREAT O_TRUNC O_WRONLY ENOENT );

sub new {
    my $class = shift;

    my $self = fields::new($class);
    $self->SUPER::new(@_);

    $self->{put_in_progress} = 0;
    $self->{put_fh} = undef;
    $self->{put_pos} = 0;

    return $self;
}

sub close {
    my Perlbal::ClientHTTP $self = shift;

    $self->{put_fh} = undef;

    $self->SUPER::close(@_);
}

sub send_response {
    my Perlbal::ClientHTTP $self = shift;

    $self->watch_read(0);
    $self->watch_write(1);
    return $self->_simple_response(@_);
}

sub event_read {
    my Perlbal::ClientHTTP $self = shift;

    # see if we have headers?
    if ($self->{req_headers}) {
        if ($self->{req_headers}->request_method eq 'PUT') {
            # read in data and shove it on the read buffer
            if (defined (my $dataref = $self->read($self->{content_length_remain}))) {
                # got some data
                $self->{read_buf} .= $$dataref;
                my $clen = length($$dataref);
                $self->{read_size} += $clen;
                $self->{content_length_remain} -= $clen;

                # handle put if we should
                $self->handle_put if $self->{read_size} >= 8192; # arbitrary

                # now, if we've filled the content of this put, we're done
                unless ($self->{content_length_remain}) {
                    $self->watch_read(0);
                    $self->handle_put;
                }
            } else {
                # undefined read, user closed on us
                $self->close;
            }
        } else {
            # since we have headers and we're not doing any special
            # handling above, let's just disable read notification, because
            # we won't do anything with the data
            $self->watch_read(0);
        }
        return;
    }

    # try and get the headers, if they're all here
    my $hd = $self->read_request_headers;
    return unless $hd;

    # notify that we're about to serve
    return if $self->{service}->run_hook('start_web_request', $self);

    # see what method it is?
    if ($hd->request_method eq 'GET' || $hd->request_method eq 'HEAD') {
        # and once we have it, start serving
        $self->watch_read(0);
        return $self->_serve_request($hd);
    } elsif ($self->{service}->{enable_put} && $hd->request_method eq 'PUT') {
        # they want to put something, so let's setup and wait for more reads
        my $clen = $hd->header('Content-length') + 0;
        
        # return a 400 (bad request) if we got no content length or if it's
        # bigger than any specified max put size
        return $self->send_response(400, "File too big? ($clen)")
            if !$clen ||
               ($self->{service}->{max_put_size} &&
                $clen > $self->{service}->{max_put_size});

        # if we have some data already from a header over-read, handle it by
        # flattening it down to a single string as opposed to an array of stuff
        if (defined $self->{read_size} && $self->{read_size} > 0) {
            my $data = '';
            foreach my $rdata (@{$self->{read_buf}}) {
                $data .= ref $rdata ? $$rdata : $rdata;
            }
            $self->{read_buf} = $data;
            $self->{content_length} = $clen;
            $self->{content_length_remain} = $clen - $self->{read_size};
        } else {
            # setup to read the file
            $self->{read_buf} = '';            
            $self->{content_length} = $self->{content_length_remain} = $clen;
        }

        # setup the directory asynchronously
        $self->setup_put;       
        return;
    }

    # else, bad request
    return $self->send_response(400);
}

# called when we've got headers and are about to start a put
sub setup_put {
    my Perlbal::ClientHTTP $self = shift;

    return if $self->{service}->run_hook('setup_put', $self);
    return if $self->{put_fh};

    # error in filename?  (any .. is an error)
    my $uri = $self->{req_headers}->request_uri;
    return $self->send_response(400, 'Invalid filename')
        if $uri =~ /\.\./;

    # now we want to get the URI
    if ($uri =~ m!^((?:/[\w\-\.]+)*)/([\w\-\.]+)$!) {
        # sanitize uri into path and file into a disk path and filename
        my ($path, $filename) = ($1 || '', $2);
        $path = $self->{service}->{docroot} . '/' . $path;
        $path = '/' . join('/', grep { defined $_ && length $_ } split('/', $path));

        # now we want to open this directory
        return $self->attempt_open($path, $filename);
    } else {
        # bad URI, don't accept the put
        $self->watch_read(0);
        return $self->send_response(400, 'Invalid filename');
    }
}

# attempt to open a file
sub attempt_open {
    my Perlbal::ClientHTTP $self = shift;
    my ($path, $file) = @_;

    $self->{put_in_progress} = 1;
    
    Linux::AIO::aio_open("$path/$file", O_CREAT | O_TRUNC | O_WRONLY, 0644, sub {
        # verify file was opened
        $self->{put_in_progress} = 0;
        if ($! == ENOENT) {
            # directory doesn't exist, so let's manually create it
            eval { File::Path::mkpath($path, 0, 0755); };
            return $self->send_response(500, 'Unable to create directory') if $@;

            # should be created, call self recursively to try
            return $self->attempt_open($path, $file);
        } elsif ($!) {
            return $self->send_response(500, "Error: $!");
        }

        # associate descriptor from aio_open with filehandle for aio_write/aio_close
        $self->{put_fh} = IO::Handle->new_from_fd(shift(), "w")
            or return $self->send_response(500, "Unable to create file: $!");
        $self->{put_pos} = 0;
        $self->handle_put;
    });
}

# called when we've got some put data to write out
sub handle_put {
    my Perlbal::ClientHTTP $self = shift;

    return if $self->{service}->run_hook('handle_put', $self);
    return if $self->{put_in_progress};
    return unless $self->{put_fh};
    return unless $self->{read_size};

    # dig out data to write
    my ($data, $count) = ($self->{read_buf}, $self->{read_size});
    ($self->{read_buf}, $self->{read_size}) = ('', 0);

    # okay, file is open, write some data
    $self->{put_in_progress} = 1;
    Linux::AIO::aio_write($self->{put_fh}, $self->{put_pos}, $count, $data, 0, sub {
        # see how many bytes written
        my $bytes = shift() + 0;
        $self->{put_pos} += $bytes;
        $self->{put_in_progress} = 0;

        # now recursively call ourselves?
        if ($self->{read_size}) {
            $self->handle_put;
        } else {
            # we done putting this file?
            unless ($self->{content_length_remain}) {
                # close it
                Linux::AIO::aio_close($self->{put_fh}, sub {
                    $self->{put_fh} = undef;
                    return $self->send_response(200);
                });
            }
        }
    });
}

1;

# Local Variables:
# mode: perl
# c-basic-indent: 4
# indent-tabs-mode: nil
# End:
