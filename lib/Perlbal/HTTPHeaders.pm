######################################################################
# HTTP header class (both request and response)
#
# Copyright 2004, Danga Interactive, Inc.
# Copyright 2005-2007, Six Apart, Ltd.
#

package Perlbal::HTTPHeaders;
use strict;
use warnings;
no  warnings qw(deprecated);

use Perlbal;

use fields (
            'headers',   # href; lowercase header -> comma-sep list of values
            'origcase',  # href; lowercase header -> provided case
            'hdorder',   # aref; order headers were received (canonical order)
            'method',    # scalar; request method (if GET request)
            'uri',       # scalar; request URI (if GET request)
            'type',      # 'res' or 'req'
            'code',      # HTTP response status code
            'codetext',  # status text that for response code
            'ver',       # version (string) "1.1"
            'vernum',    # version (number: major*1000+minor): "1.1" => 1001
            'responseLine', # first line of HTTP response (if response)
            'requestLine',  # first line of HTTP request (if request)
            );

our $HTTPCode = {
    200 => 'OK',
    204 => 'No Content',
    206 => 'Partial Content',
    301 => 'Permanent Redirect',
    302 => 'Found',
    304 => 'Not Modified',
    400 => 'Bad request',
    403 => 'Forbidden',
    404 => 'Not Found',
    416 => 'Request range not satisfiable',
    500 => 'Internal Server Error',
    501 => 'Not Implemented',
    503 => 'Service Unavailable',
};

sub fail {
    return undef unless Perlbal::DEBUG >= 1;

    my $reason = shift;
    print "HTTP parse failure: $reason\n" if Perlbal::DEBUG >= 1;
    return undef;
}

sub http_code_english {
    my Perlbal::HTTPHeaders $self = shift;
    if (@_) {
        return $HTTPCode->{shift()} || "";
    } else {
        return "" unless $self->response_code;
        return $HTTPCode->{$self->response_code} || "";
    }
}

sub new_response {
    my Perlbal::HTTPHeaders $self = shift;
    $self = fields::new($self) unless ref $self;

    my $code = shift;
    $self->{headers} = {};
    $self->{origcase} = {};
    $self->{hdorder} = [];
    $self->{method} = undef;
    $self->{uri} = undef;

    $self->{responseLine} = "HTTP/1.0 $code " . $self->http_code_english($code);
    $self->{code} = $code;
    $self->{type} = "httpres";

    Perlbal::objctor($self, $self->{type});
    return $self;
}
*new_response_PERL = \&new_response;

sub new {
    my Perlbal::HTTPHeaders $self = shift;
    $self = fields::new($self) unless ref $self;

    my ($hstr_ref, $is_response) = @_;
    # hstr: headers as a string ref
    # is_response: bool; is HTTP response (as opposed to request).  defaults to request.

    my $absoluteURIHost = undef;

    my @lines = split(/\r?\n/, $$hstr_ref);

    $self->{headers} = {};
    $self->{origcase} = {};
    $self->{hdorder} = [];
    $self->{method} = undef;
    $self->{uri} = undef;
    $self->{type} = ($is_response ? "res" : "req");
    Perlbal::objctor($self, $self->{type});

    # check request line
    if ($is_response) {
        $self->{responseLine} = (shift @lines) || "";

        # check for valid response line
        return fail("Bogus response line") unless
            $self->{responseLine} =~ m!^HTTP\/(\d+)\.(\d+)\s+(\d+)(?:\s+(.*))$!;

        my ($ver_ma, $ver_mi, $code) = ($1, $2, $3);
        $self->code($code, $4);

        # version work so we know what version the backend spoke
        unless (defined $ver_ma) {
            ($ver_ma, $ver_mi) = (0, 9);
        }
        $self->{ver} = "$ver_ma.$ver_mi";
        $self->{vernum} = $ver_ma*1000 + $ver_mi;
    } else {
        $self->{requestLine} = (shift @lines) || "";

        # check for valid request line
        return fail("Bogus request line") unless
            $self->{requestLine} =~ m!^(\w+) ((?:\*|(?:\S*?)))(?: HTTP/(\d+)\.(\d+))$!;

        $self->{method} = $1;
        $self->{uri} = $2;

        my ($ver_ma, $ver_mi) = ($3, $4);

        # now check uri for not being a uri
        if ($self->{uri} =~ m!^http://([^/:]+?)(?::\d+)?(/.*)?$!) {
            $absoluteURIHost = lc($1);
            $self->{uri} = $2 || "/"; # "http://www.foo.com" yields no path, so default to "/"
        }

        # default to HTTP/0.9
        unless (defined $ver_ma) {
            ($ver_ma, $ver_mi) = (0, 9);
        }

        $self->{ver} = "$ver_ma.$ver_mi";
        $self->{vernum} = $ver_ma*1000 + $ver_mi;
    }

    my $last_header = undef;
    foreach my $line (@lines) {
        if ($line =~ /^\s/) {
            next unless defined $last_header;
            $self->{headers}{$last_header} .= $line;
        } elsif ($line =~ /^([^\x00-\x20\x7f()<>@,;:\\\"\/\[\]?={}]+):\s*(.*)$/) {
            # RFC 2616:
            # sec 4.2:
            #     message-header = field-name ":" [ field-value ]
            #     field-name     = token
            # sec 2.2:
            #     token          = 1*<any CHAR except CTLs or separators>

            $last_header = lc($1);
            if (defined $self->{headers}{$last_header}) {
                if ($last_header eq "set-cookie") {
                    # cookie spec doesn't allow merged headers for set-cookie,
                    # so instead we do this hack so to_string below does the right
                    # thing without needing to be arrayref-aware or such.  also
                    # this lets client code still modify/delete this data
                    # (but retrieving the value of "set-cookie" will be broken)
                    $self->{headers}{$last_header} .= "\r\nSet-Cookie: $2";
                } else {
                    # normal merged header case (according to spec)
                    $self->{headers}{$last_header} .= ", $2";
                }
            } else {
                $self->{headers}{$last_header} = $2;
                $self->{origcase}{$last_header} = $1;
                push @{$self->{hdorder}}, $last_header;
            }
        } else {
            return fail("unknown header line");
        }
    }

    # override the host header if an absolute URI was provided
    $self->header('Host', $absoluteURIHost)
        if defined $absoluteURIHost;

    # now error if no host
    return fail("HTTP 1.1 requires host header")
        if !$is_response && $self->{vernum} >= 1001 && !$self->header('Host');

    return $self;
}
*new_PERL = \&new;

sub _codetext {
    my Perlbal::HTTPHeaders $self = shift;
    return $self->{codetext} if $self->{codetext};
    return $self->http_code_english;
}

sub code {
    my Perlbal::HTTPHeaders $self = shift;
    my ($code, $text) = @_;
    $self->{codetext} = $text;
    if (! defined $self->{code} || $code != $self->{code}) {
        $self->{code} = $code+0;
        if ($self->{responseLine}) {
            $self->{responseLine} = "HTTP/1.0 $code " . $self->http_code_english;
        }
    }
}

sub response_code {
    my Perlbal::HTTPHeaders $self = $_[0];
    return $self->{code};
}

sub request_method {
    my Perlbal::HTTPHeaders $self = shift;
    return $self->{method};
}

sub request_uri {
    my Perlbal::HTTPHeaders $self = shift;
    return $self->{uri};
}

sub set_request_uri {
    my Perlbal::HTTPHeaders $self = shift;
    return unless $self->{requestLine};

    my $uri = shift;

    return unless defined $uri and length $uri;

    my $ver = $self->{ver};

    if ($ver == 0.9) {
        $self->{requestLine} = sprintf("%s %s", $self->{method}, $uri);
    } else {
        $self->{requestLine} = sprintf("%s %s HTTP/%s", $self->{method}, $uri, $ver);
    }

    return $self->{uri} = $uri;
}

sub version_number {
    my Perlbal::HTTPHeaders $self = $_[0];
    return $self->{vernum} unless $_[1];
    return $self->{vernum} = $_[1];
}

sub header {
    my Perlbal::HTTPHeaders $self = shift;
    my $key = shift;
    return $self->{headers}{lc($key)} unless @_;

    # adding a new header
    my $origcase = $key;
    $key = lc($key);
    unless (exists $self->{headers}{$key}) {
        push @{$self->{hdorder}}, $key;
        $self->{origcase}{$key} = $origcase;
    }

    return $self->{headers}{$key} = shift;
}

sub headers_list {
    my Perlbal::HTTPHeaders $self = shift;
    return [] unless $self->{headers};
    return [ map { $self->{origcase}{$_} } keys %{$self->{headers}} ];
}

sub to_string_ref {
    my Perlbal::HTTPHeaders $self = shift;
    my $st = join("\r\n",
                  $self->{requestLine} || $self->{responseLine},
                  (map { "$self->{origcase}{$_}: $self->{headers}{$_}" }
                   grep { defined $self->{headers}{$_} }
                   @{$self->{hdorder}}),
                  '', '');  # final \r\n\r\n
    return \$st;
}

sub clone {
    my Perlbal::HTTPHeaders $self = shift;
    my $new = fields::new($self);
    foreach (qw(method uri type code codetext ver vernum responseLine requestLine)) {
        $new->{$_} = $self->{$_};
    }

    # mark this object as constructed
    Perlbal::objctor($new, $new->{type});

    $new->{headers} = { %{$self->{headers}} };
    $new->{origcase} = { %{$self->{origcase}} };
    $new->{hdorder} = [ @{$self->{hdorder}} ];
    return $new;
}

sub set_version {
    my Perlbal::HTTPHeaders $self = shift;
    my $ver = shift;

    die "Bogus version" unless $ver =~ /^(\d+)\.(\d+)$/;
    my ($ver_ma, $ver_mi) = ($1, $2);

    # check for req, as the other can be res or httpres
    if ($self->{type} eq 'req') {
        $self->{requestLine} = "$self->{method} $self->{uri} HTTP/$ver";
    } else {
        $self->{responseLine} = "HTTP/$ver $self->{code} " . $self->_codetext;
    }
    $self->{ver} = "$ver_ma.$ver_mi";
    $self->{vernum} = $ver_ma*1000 + $ver_mi;
    return $self;
}

# using all available information, attempt to determine the content length of
# the message body being sent to us.
sub content_length {
    my Perlbal::HTTPHeaders $self = shift;

    # shortcuts depending on our method/code, depending on what we are
    if ($self->{type} eq 'req') {
        # no content length for head requests
        return 0 if $self->{method} eq 'HEAD';
    } elsif ($self->{type} eq 'res' || $self->{type} eq 'httpres') {
        # no content length in any of these
        if ($self->{code} == 304 || $self->{code} == 204 ||
            ($self->{code} >= 100 && $self->{code} <= 199)) {
            return 0;
        }
    }

    # the normal case for a GET/POST, etc.  real data coming back
    # also, an OPTIONS requests generally has a defined but 0 content-length
    if (defined(my $clen = $self->header("Content-Length"))) {
        return $clen;
    }

    # if we get here, nothing matched, so we don't definitively know what the
    # content length is.  this is usually an error, but we try to work around it.
    return undef;
}

# answers the question: "should a response to this person specify keep-alive,
# given the request (self) and the backend response?"  this is used in proxy
# mode to determine based on the client's request and the backend's response
# whether or not the response from the proxy (us) should do keep-alive.
#
# FIXME: this is called too often (especially with service selector),
# and should be redesigned to be simpler, and/or cached on the
# connection.  there's too much duplication with res_keep_alive.
sub req_keep_alive {
    my Perlbal::HTTPHeaders $self = $_[0];
    my Perlbal::HTTPHeaders $res = $_[1] or Carp::confess("ASSERT: No response headers given");

    # get the connection header now (saves warnings later)
    my $conn = lc ($self->header('Connection') || '');

    # check the client
    if ($self->version_number < 1001) {
        # they must specify a keep-alive header
        return 0 unless $conn =~ /\bkeep-alive\b/i;
    }

    # so it must be 1.1 which means keep-alive is on, unless they say not to
    return 0 if $conn =~ /\bclose\b/i;

    # if we get here, the user wants keep-alive and seems to support it,
    # so we make sure that the response is in a form that we can understand
    # well enough to do keep-alive.  FIXME: support chunked encoding in the
    # future, which means this check changes.
    return 1 if defined $res->header('Content-length') ||
        $res->response_code == 304 || # not modified
        $res->response_code == 204 || # no content
        $self->request_method eq 'HEAD';

    # fail-safe, no keep-alive
    return 0;
}

# if an options response from a backend looks like it can do keep-alive.
sub res_keep_alive_options {
    my Perlbal::HTTPHeaders $self = $_[0];
    return $self->res_keep_alive(undef, 1);
}

# answers the question: "is the backend expected to stay open?"  this
# is a combination of the request we sent to it and the response they
# sent...

# FIXME: this is called too often (especially with service selector),
# and should be redesigned to be simpler, and/or cached on the
# connection.  there's too much duplication with req_keep_alive.
sub res_keep_alive {
    my Perlbal::HTTPHeaders $self = $_[0];
    my Perlbal::HTTPHeaders $req = $_[1];
    my $is_options = $_[2];
    Carp::confess("ASSERT: No request headers given") unless $req || $is_options;

    # get the connection header now (saves warnings later)
    my $conn = lc ($self->header('Connection') || '');

    # if they said Connection: close, it's always not keep-alive
    return 0 if $conn =~ /\bclose\b/i;

    # handle the http 1.0/0.9 case which requires keep-alive specified
    if ($self->version_number < 1001) {
        # must specify keep-alive, and must have a content length OR
        # the request must be a head request
        return 1 if
            $conn =~ /\bkeep-alive\b/i &&
            ($is_options ||
             defined $self->header('Content-length') ||
             $req->request_method eq 'HEAD' ||
             $self->response_code == 304 || # not modified
             $self->response_code == 204
             ); # no content

        return 0;
    }

    # HTTP/1.1 case.  defaults to keep-alive, per spec, unless
    # asked for otherwise (checked above)
    # FIXME: make sure we handle a HTTP/1.1 response from backend
    # with connection: close, no content-length, going to a
    # HTTP/1.1 persistent client.  we'll have to add chunk markers.
    # (not here, obviously)
    return 1;
}

# returns (status, range_start, range_end) when given a size
# status = 200 - invalid or non-existent range header.  serve normally.
# status = 206 - parseable range is good.  serve partial content.
# status = 416 - Range is unsatisfiable
sub range {
    my Perlbal::HTTPHeaders $self = $_[0];
    my $size = $_[1];

    my $not_satisfiable;
    my $range = $self->header("Range");

    return 200 unless
        $range &&
        defined $size &&
        $range =~ /^bytes=(\d*)-(\d*)$/;

    my ($range_start, $range_end) = ($1, $2);

    undef $range_start if $range_start eq '';
    undef $range_end if $range_end eq '';
    return 200 unless defined($range_start) or defined($range_end);

    if (defined($range_start) and defined($range_end) and $range_start > $range_end)  {
        return 416;
    } elsif (not defined($range_start) and defined($range_end) and $range_end == 0)  {
        return 416;
    } elsif (defined($range_start) and $size <= $range_start) {
        return 416;
    }

    $range_start = 0        unless defined($range_start);
    $range_end  = $size - 1 unless defined($range_end) and $range_end < $size;

    return (206, $range_start, $range_end);
}


sub DESTROY {
    my Perlbal::HTTPHeaders $self = shift;
    Perlbal::objdtor($self, $self->{type});
}

1;

# Local Variables:
# mode: perl
# c-basic-indent: 4
# indent-tabs-mode: nil
# End:
