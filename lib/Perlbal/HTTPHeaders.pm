######################################################################
# HTTP header class (both request and response)
######################################################################

package Perlbal::HTTPHeaders;
use strict;
use fields (
            'headers',   # href; lowercase header -> comma-sep list of values
            'origcase',  # href; lowercase header -> provided case
            'hdorder',   # aref; order headers were received (canonical order)
            'method',    # scalar; request method (if GET request)
            'uri',       # scalar; request URI (if GET request)
            'type',      # 'res' or 'req'
            'code',      # HTTP status code
            'responseLine', # first line of HTTP response (if response)
            'requestLine',  # first line of HTTP request (if request)
            );

our $HTTPCode = {
    200 => 'OK',
    304 => 'Not Modified',
    400 => 'Bad request',
    403 => 'Forbidden',
    404 => 'Not Found',
    500 => 'Internal Server Error',
    501 => 'Not Implemented',
};

sub fail {
    return undef unless Perlbal::DEBUG >= 1;

    my $reason = shift;
    print "HTTP parse failure: $reason\n" if Perlbal::DEBUG >= 1;
    return undef;
}

sub http_code_english {
    my Perlbal::HTTPHeaders $self = shift;
    return $HTTPCode->{$self->{code}};
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

    my $msg = $HTTPCode->{$code} || "";
    $self->{responseLine} = "HTTP/1.0 $code $msg";
    $self->{code} = $code;
    $self->{type} = "httpres";

    Perlbal::objctor($self->{type});
    return $self;
}

sub new {
    my Perlbal::HTTPHeaders $self = shift;
    $self = fields::new($self) unless ref $self;

    my ($hstr, $is_response) = @_;
    # hstr: headers as a string
    # is_response: bool; is HTTP response (as opposed to request).  defaults to request.

    $hstr =~ s!\r!!g;
    my @lines = split(/\n/, $hstr);
    my $first = (shift @lines) || "";

    $self->{headers} = {};
    $self->{origcase} = {};
    $self->{hdorder} = [];
    $self->{method} = undef;
    $self->{uri} = undef;
    $self->{type} = ($is_response ? "res" : "req");
    Perlbal::objctor($self->{type});

    # check request line
    if ($is_response) {
        # check for valid response line
        return fail("Bogus response line") unless
            $first =~ m!^HTTP\/(\d+\.\d+)\s+(\d+)!;
        my ($ver, $code) = ($1, $2);
        $self->{code} = $2;
        $self->{responseLine} = $first;
    } else {
        # check for valid request line
        return fail("Bogus request line") unless
            $first =~ m!^(\w+) ((?:\*|(?:/\S*?)))(?: HTTP/(\d+\.\d+))$!;

        my ($method, $uri, $ver) = ($1, $2, $3);
        print "Method: [$method] URI: [$uri] Version: [$ver]\n" if Perlbal::DEBUG >= 1;
        $ver ||= "1.0";

        $self->{requestLine} = "$method $uri HTTP/$ver";
        $self->{method} = $method;
        $self->{uri} = $uri;
    }

    my $last_header = undef;
    foreach my $line (@lines) {
        if ($line =~ /^(\s+.*?)$/) {
            next unless defined $last_header;
            $self->{headers}{$last_header} .= $1;
        } elsif ($line =~ /^([^\x00-\x20\x7f\(\)\<\>\@,;:\\\"\/\[\]\?=\{\}]+):\s*(.*?)$/) {
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

    return $self;
}

sub request_method {
    my Perlbal::HTTPHeaders $self = shift;
    return $self->{method};
}

sub request_uri {
    my Perlbal::HTTPHeaders $self = shift;
    return $self->{uri};
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

sub DESTROY {
    my Perlbal::HTTPHeaders $self = shift;
    Perlbal::objdtor($self->{type});
}

1;

# Local Variables:
# mode: perl
# c-basic-indent: 4
# indent-tabs-mode: nil
# End:
