######################################################################
# HTTP header class (both request and response)
######################################################################

package Perlbal::HTTPHeaders;
use strict;

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
    my $self = shift;
    return $HTTPCode->{$self->{code}};
}

sub new_response {
    my ($class, $code) = @_;

    my $self = {
	headers => {},      # lowercase header -> comma-sep list of values
	origcase => {},     # lowercase header -> provided case
	hdorder => [],      # order headers were received (canonical order)
	method => undef,    # request method (if GET request)
	uri => undef,       # request URI (if GET request)
    };

    my $msg = $HTTPCode->{$code} || "";
    $self->{responseLine} = "HTTP/1.0 $code $msg";
    $self->{code} = $code;

    return bless $self, ref $class || $class;
}

sub new {
    my ($class, $hstr, $is_response) = @_;
    # hstr: headers as a string
    # is_response: bool; is HTTP response (as opposed to request).  defaults to request.

    $hstr =~ s!\r!!g;
    my @lines = split(/\n/, $hstr);
    my $first = shift @lines;

    my $self = {
	headers => {},      # lowercase header -> comma-sep list of values
	origcase => {},     # lowercase header -> provided case
	hdorder => [],      # order headers were received (canonical order)
	method => undef,    # request method (if GET request)
	uri => undef,       # request URI (if GET request)
    };

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
	$self->{requestLine} = "$method $uri HTTP/1.0";
	$self->{method} = $method;
	$self->{uri} = $uri;
    }

    my $last_header = undef;
    foreach my $line (@lines) {
	if ($line =~ /^(\s+.*?)$/) {
	    next unless defined $last_header;
	    $self->{headers}{$last_header} .= $1;
	} elsif ($line =~ /^([\w\-]+):\s*(.*?)$/) {
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

    return bless $self, ref $class || $class;
}

sub request_method {
    my $self = shift;
    return $self->{method};
}

sub request_uri {
    my $self = shift;
    return $self->{uri};
}

sub header {
    my $self = shift;
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
    my $self = shift;
    my $st = join("\r\n", 
		  $self->{requestLine} || $self->{responseLine},
		  map { "$self->{origcase}{$_}: $self->{headers}{$_}" }
		  grep { defined $self->{headers}{$_} }
		  @{$self->{hdorder}},
		  ) . "\r\n\r\n";
    return \$st;
}

1;
