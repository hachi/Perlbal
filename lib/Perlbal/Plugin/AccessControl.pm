package Perlbal::Plugin::AccessControl;

use Perlbal;
use strict;
use warnings;
no  warnings qw(deprecated);

# commands like:
#
#  access default deny
#  access allow 127.0.0.1/24
#  access allow 127.0.0.1/24
#  access reset
#  access deny 129.0.0.5
#


# when "LOAD" directive loads us up
sub load {
    my $class = shift;

    Perlbal::register_global_hook('manage_command.access', sub {
        my $mc = shift->parse(qr/^access\s+(?:(\w+)\s+)?(\S+)\s+(\w+)$/,
                              "usage: ACCESS [<service>] <action> <arg>");
        my ($svcname, $action, $arg) = $mc->args;
        unless ($svcname ||= $mc->{ctx}{last_created}) {
            return $mc->err("omitted service name not implied from context");
        }

        my $ss = Perlbal->service($selname);
        return $mc->err("Service '$selname' doesn't exist")
            unless $ss && $ss->{role} eq "selector";


        $ss->{extra_config}->{_vhosts} ||= {};
        $ss->{extra_config}->{_vhosts}{$host} = $target;

        return $mc->ok;
    });
    return 1;
}

# unload our global commands, clear our service object
sub unload {
    my $class = shift;

    Perlbal::unregister_global_hook('manage_command.vhost');
    unregister($class, $_) foreach (values %Services);
    return 1;
}

# called when we're being added to a service
sub register {
    my ($class, $svc) = @_;

    my $notes = $notes{$svc->{name}} ||= {};

    $svc->register_hook('AccessControl', 'start_http_request', sub {
        my Perlbal::ClientHTTPBase $client = shift;
        my Perlbal::HTTPHeaders $hds = $client->{req_headers};
        return 0 unless $hds;
        my $uri = $hds->request_uri;
        return 0 unless $uri =~ m!^/bad!;


        my

        if (1) {
            $client->send_response(403, "Access denied.");
            return 1;
        }

    });

    return 1;
}

# called when we're no longer active on a service
sub unregister {
    my ($class, $svc) = @_;
    #delete $notes{..} ?
    return 1;
}

1;
