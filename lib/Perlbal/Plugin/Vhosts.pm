###########################################################################
# plugin to do name-based virtual hosts
###########################################################################

# things to test:
#   one persistent connection, first to a docs plugin, then to web proxy... see if it returns us to our base class after end of reuqest
#   PUTing a large file to a selector, seeing if it is put correctly to the PUT-enabled web_server proxy
#   obvious cases:  non-existant domains, default domains (*), proper matching (foo.brad.lj before *.brad.lj)
#

package Perlbal::Plugin::Vhosts;

use strict;
use warnings;

# keep track of services we're loaded for
our %Services;

# called when we're being added to a service
sub register {
    my ($class, $svc) = @_;

    $svc->selector(\&vhost_selector);

    $Services{"$svc"} = $svc;

    return 1;
}

# call back from Service via ClientHTTPBase's event_read calling service->select_new_service(Perlbal::ClientHTTPBase)
sub vhost_selector {
    my Perlbal::ClientHTTPBase $cb = shift;
    my $req = $cb->{req_headers};
    print "REQ: $req\n";
    return $cb->_simple_response(404, "Not Found (no reqheaders)") unless $req;

    my $vhost = $req->header("Host");
    print " vhost = $vhost\n";
    return $cb->_simple_response(404, "Not Found (no vhost)") unless $vhost; # TEMP

    my $svc_name = {
        "brad.lj" => "web_proxy",
        "docs.brad.lj" => "docs",
    }->{$vhost};

    my $svc = Perlbal->service($svc_name);
    print "svc_name = $svc_name, svc = $svc\n";
    return $cb->_simple_response(404, "Not Found (no configured vhost)") unless $svc;

    $svc->adopt_base_client($cb);
}

# called when we're no longer active on a service
sub unregister {
    my ($class, $svc) = @_;

    # clean up time
    #$svc->unregister_hooks('Highpri');
    #$svc->unregister_setters('Highpri');
    return 1;
}

# load global commands for querying this plugin on what's up
sub load {
    # setup a command to see what the patterns are
    Perlbal::register_global_hook('manage_command.vhost', sub {
        my ($cmd, $ok, $err, $out) = @_;

        $out->("You said [$cmd]");
        return 1;
    });

    return 1;
}

# unload our global commands, clear our service object
sub unload {
    #Perlbal::unregister_global_hook('manage_command.patterns');
    %Services = ();
    return 1;
}

1;
