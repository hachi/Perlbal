######################################################################
# Base class for all socket types
######################################################################

package Perlbal::Socket;
use strict;
use Perlbal::HTTPHeaders;

use base 'Danga::Socket';
use fields (
            'headers_string',  # headers as they're being read
            'headers',         # the final Perlbal::HTTPHeaders object
            'create_time',     # creation time
            );

use constant MAX_HTTP_HEADER_LENGTH => 102400;  # 100k, arbitrary

sub new {
    my Perlbal::Socket $self = shift;
    $self = fields::new( $self ) unless ref $self;

    Perlbal::objctor();

    $self->SUPER::new( @_ );
    $self->{headers_string} = '';
    $self->{create_time} = time();

    return $self;
}


# Socket: specific to HTTP socket types
sub read_headers {
    my Perlbal::Socket $self = shift;
    my $is_res = shift;

    my $sock = $self->{sock};

    my $to_read = MAX_HTTP_HEADER_LENGTH - length($self->{headers_string});

    my $bref = $self->read($to_read);
    return $self->close if ! defined $bref;  # client disconnected

    $self->{headers_string} .= $$bref;
    my $idx = index($self->{headers_string}, "\r\n\r\n");

    # can't find the header delimiter?
    if ($idx == -1) {
        $self->close('long_headers')
            if length($self->{headers_string}) >= MAX_HTTP_HEADER_LENGTH;
        return 0;
    }

    $self->{headers} = substr($self->{headers_string}, 0, $idx);
    print "HEADERS: [$self->{headers}]\n" if Perlbal::DEBUG >= 2;

    my $extra = substr($self->{headers_string}, $idx+4);
    if (my $len = length($extra)) {
        push @{$self->{read_buf}}, \$extra;
        $self->{read_size} = $self->{read_ahead} = length($extra);
        print "post-header extra: $len bytes\n" if Perlbal::DEBUG >= 2;
    }

    unless ($self->{headers} = Perlbal::HTTPHeaders->new($self->{headers}, $is_res)) {
        # bogus headers?  close connection.
        return $self->close("parse_header_failure");
    }

    return $self->{headers};
}


sub read_request_headers  { read_headers(@_, 0); }
sub read_response_headers { read_headers(@_, 1); }

sub as_string_html {
    my Perlbal::Socket $self = shift;
    return $self->SUPER::as_string;
}

sub DESTROY {
    Perlbal::objdtor();
}

1;


# Local Variables:
# mode: perl
# c-basic-indent: 4
# indent-tabs-mode: nil
# End:
