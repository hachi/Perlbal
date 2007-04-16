package Perlbal::Plugin::AccessControl;

use Perlbal;
use strict;
use warnings;
no  warnings qw(deprecated);

# commands like:
#
# what to do if we fall off the rule chain:
#     ACCESS POLICY {ALLOW,DENY}
#
# adding things to the rule chain.  processing stops once any rule is matched.
#
#     ACCESS {ALLOW,DENY} netmask 127.0.0.1/8
#     ACCESS {ALLOW,DENY} ip 127.0.0.1
# also can make a match set the request to go into the low-priority perlbal queue:
#     ACCESS QUEUE_LOW ip 127.0.0.1

# reset the rule chain and policy:  (policy is allow by default)
#     ACCESS RESET

# Future:
#  access {allow,deny} forwarded_ip 127.0.0.1
#  access {allow,deny} method <method>[,<method>]*
#  access {allow,deny} forwarded_netmask 127.0.0.1/24

sub load {
    my $class = shift;

    Perlbal::register_global_hook('manage_command.access', sub {
        my $mc = shift->parse(qr/^access\s+
                              (policy|allow|deny|reset|queue_low)      # cmd
                              (?:\s+(\S+))?                  # arg1
                              (?:\s+(\S+))?                  # optional arg2
                              $/x,
                              "usage: ACCESS [<service>] <cmd> <arg1> [<arg2>]");
        my ($cmd, $arg1, $arg2) = $mc->args;

        my $svcname;
        unless ($svcname ||= $mc->{ctx}{last_created}) {
            return $mc->err("No service name in context from CREATE SERVICE <name> or USE <service_name>");
        }

        my $ss = Perlbal->service($svcname);
        return $mc->err("Non-existent service '$svcname'") unless $ss;

        my $cfg = $ss->{extra_config}->{_access} ||= {};

        if ($cmd eq "reset") {
            $ss->{extra_config}->{_access} = {};
            return $mc->ok;
        }

        if ($cmd eq "policy") {
            return $mc->err("policy must be 'allow' or 'deny'") unless
                $arg1 =~ /^allow|deny$/;
            $cfg->{deny_default} = $arg1 eq "deny";
            return $mc->ok;
        }

        if ($cmd eq "allow" || $cmd eq "deny" || $cmd eq "queue_low") {
            my ($what, $val) = ($arg1, $arg2);
            return $mc->err("Unknown item to $cmd: '$what'") unless
                $what && ($what eq "ip" || $what eq "netmask");

            if ($what eq "netmask") {
                return $mc->err("Net::Netmask not installed")
                    unless eval { require Net::Netmask; 1; };

                $val = eval { Net::Netmask->new2($val) };
                return $mc->err("Error parsing netmask") unless $val;
            }

            my $rules = $cfg->{rules} ||= [];
            push @$rules, [ $cmd, $what, $val ];
            return $mc->ok;
        }

        return $mc->err("can't get here");
    });

    return 1;
}

# unload our global commands, clear our service object
sub unload {
    my $class = shift;
    Perlbal::unregister_global_hook('manage_command.vhost');
    return 1;
}

# called when we're being added to a service
sub register {
    my ($class, $svc) = @_;

    $svc->register_hook('AccessControl', 'start_http_request', sub {
        my Perlbal::ClientHTTPBase $client = shift;
        my Perlbal::HTTPHeaders $hds = $client->{req_headers};
        return 0 unless $hds;
        my $uri = $hds->request_uri;

        my $allow = sub { 0; };
        my $deny = sub {
            $client->send_response(403, "Access denied.");
            return 1;
        };

        my $queue_low = sub {
            $client->set_queue_low;
            return 0;
        };

        my $rule_action = sub {
            my $rule = shift;
            if ($rule->[0] eq "deny") {
                return $deny->();
            } elsif ($rule->[0] eq "allow") {
                return $allow->();
            } elsif ($rule->[0] eq "queue_low") {
                return $queue_low->();
            }
        };

        my $match = sub {
            my $rule = shift;
            if ($rule->[1] eq "ip") {
                my $peer_ip = $client->peer_ip_string;
                return $peer_ip eq $rule->[2];
            }

            if ($rule->[1] eq "netmask") {
                my $peer_ip = $client->peer_ip_string;
                return eval { $rule->[2]->match($peer_ip); };
            }

        };

        my $cfg = $svc->{extra_config}->{_access} ||= {};
        my $rules = $cfg->{rules} || [];
        foreach my $rule (@$rules) {
            next unless $match->($rule);
            return $rule_action->($rule)
        }

        return $deny->() if $cfg->{deny_default};
        return $allow->();
    });

    return 1;
}

# called when we're no longer active on a service
sub unregister {
    my ($class, $svc) = @_;
    return 1;
}

1;
