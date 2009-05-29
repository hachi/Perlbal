package Perlbal::Plugin::Redirect;
use strict;
use warnings;

sub handle_request {
    my ($svc, $pb) = @_;

    my $mappings = $svc->{extra_config}{_redirect_host};
    my $req_header = $pb->{req_headers};

    # returns 1 if done with client, 0 if no action taken
    my $map_using = sub {
        my ($match_on) = @_;

        my $target_host = $mappings->{$match_on};

        return 0 unless $target_host;

        my $path = $req_header->request_uri;

        my $res_header = Perlbal::HTTPHeaders->new_response(301);
        $res_header->header('Location' => "http://$target_host$path");
        $res_header->header('Content-Length' => 0);
        # For some reason a follow-up request gets a "400 Bad request" response,
        # so until someone has time to figure out why, just punt and disable 
        # keep-alives after this request.
        $res_header->header('Connection' => 'close');
        $pb->write($res_header->to_string_ref());

        return 1;
    };

    # The following is lifted wholesale from the vhosts plugin.
    # FIXME: Factor it out to a utility function, I guess?
    #
    #  foo.site.com  should match:
    #      foo.site.com
    #    *.foo.site.com
    #        *.site.com
    #             *.com
    #                 *

    my $vhost = lc($req_header->header("Host"));

    # if no vhost, just try the * mapping
    return $map_using->("*") unless $vhost;

    # Strip off the :portnumber, if any
    $vhost =~ s/:\d+$//;

    # try the literal mapping
    return 1 if $map_using->($vhost);

    # and now try wildcard mappings, removing one part of the domain
    # at a time until we find something, or end up at "*"

    # first wildcard, prepending the "*."
    my $wild = "*.$vhost";
    return 1 if $map_using->($wild);

    # now peel away subdomains
    while ($wild =~ s/^\*\.[\w\-\_]+/*/) {
        return 1 if $map_using->($wild);
    }

    # last option: use the "*" wildcard
    return $map_using->("*");
}

sub register {
    my ($class, $svc) = @_;

    $svc->register_hook('Redirect', 'start_http_request', sub { handle_request($svc, $_[0]); });
}

sub unregister {
    my ($class, $svc) = @_;
    $svc->unregister_hooks('Redirect');
}

sub handle_redirect_command {
    my $mc = shift->parse(qr/^redirect\s+host\s+(\S+)\s+(\S+)$/, "usage: REDIRECT HOST <match_host> <target_host>");
    my ($match_host, $target_host) = $mc->args;

    my $svcname;
    unless ($svcname ||= $mc->{ctx}{last_created}) {
        return $mc->err("No service name in context from CREATE SERVICE <name> or USE <service_name>");
    }

    my $svc = Perlbal->service($svcname);
    return $mc->err("Non-existent service '$svcname'") unless $svc;

    $svc->{extra_config}{_redirect_host} ||= {};
    $svc->{extra_config}{_redirect_host}{lc($match_host)} = lc($target_host);

    return 1;
}

# called when we are loaded
sub load {
    Perlbal::register_global_hook('manage_command.redirect', \&handle_redirect_command);

    return 1;
}

# called for a global unload
sub unload {
    return 1;
}

1;

=head1 NAME

Perlbal::Plugin::Redirect - Plugin to do redirecting in Perlbal land

=head1 SYNOPSIS

    LOAD redirect
    
    CREATE SERVICE redirector
        SET role = web_server
        SET plugins = redirect
        REDIRECT HOST example.com www.example.net
    ENABLE redirector

=head1 LIMITATIONS

Right now this can only redirect at the hostname level. Also, it just
assumes you want an http: URL.
