#!/usr/bin/perl
#
# Copyright 2007 Martin Atkins <mart@degeneration.co.uk> and Six Apart Ltd.
#

=head1 NAME

Perlbal::Plugin::Cgilike - Handle Perlbal requests with a Perl subroutine

=head1 DESCRIPTION

This module allows responses to be handled with a simple API that's similar in principle to
CGI, mod_perl response handlers, etc.

It does not, however, come anywhere close to conforming to the CGI "standard". It's actually
more like mod_perl in usage, though there are several differences.
Most notably, Perlbal is single-process and single-threaded, and handlers run inside the Perlbal
process and must therefore return quickly and not do any blocking operations.

As it currently stands, this is very bare-bones and has only really been used with basic GET
requests. It lacks a nice API for handling the body of a POST or PUT request.

It is not recommended to use this for extensive applications. Perlbal is first and foremost
a load balancer, so if you're doing something at all complicated you're probably better off
using something like Apache mod_perl and then putting Perlbal in front if it if necessary.
However, this plugin may prove useful for simple handlers or perhaps embedding a simple
HTTP service into another application that uses C<Danga::Socket>.

=head1 SYNOPSIS

This module provides a Perlbal plugin which can be loaded and used as follows.

	LOAD cgilike
	PERLREQUIRE = MyPackage
	
	CREATE SERVICE cgilike
		SET role   = web_server
		SET listen = 127.0.0.1:80
		SET plugins = cgilike
		PERLHANDLER = MyPackage::handler
	ENABLE cgilike

With this plugin loaded into a particular service, the plugin will then be called for
all requests for that service.

Set cgilike.handler to the name of a subroutine that will handle requests. This subroutine
will receive an object which allows interaction with the Perlbal service.

	package MyPackage
	sub handler {
	    my ($r) = @_;
		if ($r->uri eq '/') {
			print "<p>Hello, world</p>";
			return Perlbal::Plugin::Cgilike::HANDLED;
		}
		else {
			return 404;
		}
	}

Return C<Perlbal::Plugin::Cgilike::HANDLED> to indicate that the request has been handled, or return some HTTP error code
to produce a predefined error message.
You may also return C<Perlbal::Plugin::Cgilike::DECLINED> if you do not wish to handle the request, in which case Perlbal
will be allowed to handle the request in whatever way it would have done without Cgilike loaded.

If your handler returns any non-success value, it B<MUST NOT> produce any output. If you
produce output before returning such a value, the response to the client is likely to be
utter nonsense.

You may also return C<Perlbal::Plugin::Cgilike::POSTPONE_RESPONSE>, which is equivalent to
returning zero except that the HTTP connection will be left open once you return. It is
your responsibility to later call C<$r-E<gt>end_response()> when you have completed
the response. This style is necessary when you need to perform some long operation
before you can return a response; you'll need to use some appropriate method to set
a callback to run when the operation completes and then do your response in the
callback. Once you've called C<end_response>, you must not call any further methods on C<$r>;
it's probably safest to just return immediately afterwards to avoid any mishaps.

=head1 API DOCUMENTATION

TODO: Write this

=head1 TODO

Currently there is no API for dealing with the body of a POST or PUT request. Ideally it'd be able
to do automatic decoding of application/x-www-form-urlencoded data, too.

The POSTPONE_RESPONSE functionality has not been tested extensively and is probably buggy.

=head1 COPYRIGHT AND LICENSE

Copyright 2007 Martin Atkins <mart@degeneration.co.uk> and Six Apart Ltd.

This module is part of the Perlbal distribution, and as such can be distributed under the same licence terms as the rest of Perlbal.

=cut

package Perlbal::Plugin::Cgilike;

use Perlbal;
use strict;
use Symbol;

use constant DECLINED => -2;
use constant HANDLED => 0;
use constant POSTPONE_RESPONSE => -1;

sub register {
    my ($class, $svc) = @_;

    $svc->register_hook('Cgilike', 'start_http_request', sub { Perlbal::Plugin::Cgilike::handle_request($svc, $_[0]); });

}

sub handle_request {
    my Perlbal::Service $svc = shift;
    my Perlbal::ClientProxy $pb = shift;
    return 0 unless $pb->{req_headers};

    # Create a new request object, and tie a filehandle to it
    my $output_handle = Symbol::gensym();
    my $req = tie(*{$output_handle}, 'Perlbal::Plugin::Cgilike::Request', $pb);

    my $handler = $svc->{extra_config}->{_perlhandler};
    if (! defined($handler)) {
        return $pb->send_response(500, "No perlhandler is configured for this service");
    }

    # Our $output_handle is tied to the request object, which provides PRINT and PRINTF methods
    # Set it as the default so that handlers can just use print and printf as normal.
    my $oldfh = select($output_handle);

    my $ret;
    my $result = eval {
        no strict;
        $ret = &{$handler}($req);
        1;
    };

    # Restore the old filehandle to avoid breaking anyone else
    select($oldfh);

    if ($result) {
        if ($ret == 0 || $ret == POSTPONE_RESPONSE) {
            if ($ret == 0) {
                $req->end_response();
                untie($req);
            }
            return 1;
        }
        elsif ($ret == DECLINED) {
            return 0;
        }
        else {
            return $pb->send_response($ret+0, $ret+0);
        }
    }
    else {
        return $pb->send_response(500, "Error in handler: ".$@);
    }

    return $pb->send_response(500, "I seem to have fallen into a place I shouldn't be.");

}

sub handle_perlrequire_command {
    # This is defined with an equals because Perlbal lowercases all manage commands except
    # after an equals, which means that having an equals here is the only way to actually
    # get the correct case of the module name. Lame++.
    my $mc = shift->parse(qr/^perlrequire\s*=\s*([\w:]+)$/, "usage: PERLREQUIRE=<module>");
    my ($module) = $mc->args;

    my $success = eval "require $module; 1;";

    unless ($success) {
        return $mc->err("Failed to load $module: $@")
    }

    return 1;
}

sub handle_perlhandler_command {
    my $mc = shift->parse(qr/^perlhandler\s*=\s*([\w:]+)$/, "usage: PERLHANDLER=<package::subroutine>");
    my ($subname) = $mc->args;

    my $svcname;
    unless ($svcname ||= $mc->{ctx}{last_created}) {
        return $mc->err("No service name in context from CREATE SERVICE <name> or USE <service_name>");
    }

    my $svc = Perlbal->service($svcname);
    return $mc->err("Non-existent service '$svcname'") unless $svc;

    my $cfg = $svc->{extra_config}->{_perlhandler} = $subname;

    return 1;
}

# called when we're no longer active on a service
sub unregister {
    my ($class, $svc) = @_;

    $svc->unregister_hooks('Cgilike');
    return 1;
}

# called when we are loaded
sub load {
    Perlbal::register_global_hook('manage_command.perlrequire', \&Perlbal::Plugin::Cgilike::handle_perlrequire_command);
    Perlbal::register_global_hook('manage_command.perlhandler', \&Perlbal::Plugin::Cgilike::handle_perlhandler_command);

    return 1;
}

# called for a global unload
sub unload {
    return 1;
}

package Perlbal::Plugin::Cgilike::Request;

use URI;

sub new {
    my ($class, $pb) = @_;

    return bless {
        pb => $pb,
        header_sent => 0,
    }, $class;
}

# This class can also provide a tied handle which supports PRINT and PRINTF (but not much else)
sub TIEHANDLE {
    my ($class, $req_headers) = @_;
    return $class->new($req_headers);
}

sub request_header {
    return $_[0]->{pb}->{req_headers};
}

sub response_header {
    my ($self, $k, $v) = @_;

    if (defined($k)) {
        my $hdrs = $self->response_header;
        if (defined($v)) {
            $hdrs->header($k => $v);
            return $v;
        }
        else {
            return $hdrs->header($k);
        }
    }
    else {
        if (defined($self->{response_headers})) {
            return $self->{response_headers};
        }
        else {
            return $self->{response_headers} = Perlbal::HTTPHeaders->new_response(200);
        }
    }
}

sub response_status_code {
    my ($self, $value) = @_;

    my $res = $self->response_header;
    if (defined($value)) {
        $res->code($value);
    }

    return $res->response_code;
}

sub uri {
    my ($self) = @_;
    return $self->{uri} ? $self->{uri} : $self->{uri} = URI->new($self->request_header->request_uri);
}

sub path {
    my ($self) = @_;
    return $self->uri->path;
}

sub path_segments {
    my ($self) = @_;
    my @segments = $self->uri->path_segments;
    shift @segments; # Get rid of the empty segment at the start
    return @segments;
}

sub query_string {
    my ($self) = @_;
    return $self->uri->query;
}

sub query_args {
    my ($self) = @_;
    return $self->uri->query_form;
}

sub method {
    my ($self) = @_;
    return $self->request_header->request_method;
}

sub send_response_header {
    my ($self) = @_;
    $self->response_header('Content-type' => 'text/html') unless $self->response_header('Content-type');
    $self->{pb}->write($self->response_header->to_string_ref);
    $self->{header_sent} = 1;
}

sub response_header_sent {
    return $_[0]->{header_sent} ? 1 : 0;
}

sub PRINT {
    my ($self, @stuff) = @_;
    $self->print(@stuff);
}

sub PRINTF {
    my ($self, $format, @stuff) = @_;
    $self->print(sprintf($format, @stuff));
}

sub print {
    my ($self, @stuff) = @_;
    if (! $self->response_header_sent) {
        $self->send_response_header();
    }
    $self->{pb}->write(join("", @stuff));
}

sub end_response {
    my ($self) = @_;
    $self->{pb}->write(sub { $self->{pb}->http_response_sent; });
}

1;
