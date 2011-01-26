package Perlbal::Plugin::Throttle;

use strict;
use warnings;

our $VERSION = '1.20';

use List::Util 'min';
use Danga::Socket 1.59;
use Perlbal 1.70;
use Perlbal::ClientProxy ();
use Perlbal::HTTPHeaders ();
use Time::HiRes ();

# Debugging flag
use constant VERBOSE => $ENV{THROTTLE_VERBOSE} || 0;

sub load {
    Perlbal::Service::add_tunable(
        whitelist_file => {
            check_role => '*',
            des => "File containing CIDRs which are never throttled. Net::CIDR::Lite must be installed.",
            default => undef,
        }
    );
    Perlbal::Service::add_tunable(
        blacklist_file => {
            check_role => '*',
            des => "File containing CIDRs which are always blocked outright. Net::CIDR::Lite must be installed.",
            default => undef,
        }
    );
    Perlbal::Service::add_tunable(
        throttle_threshold_seconds => {
            check_role => '*',
            des => "Minimum allowable time between requests. If a non-white/-blacklisted client makes another connection within this interval, it will be throttled for min_delay seconds. Further connections will double the delay time.",
            default => 60,
            check_type => 'int',
        }
    );
    Perlbal::Service::add_tunable(
        min_delay => {
            check_role => '*',
            des => "Minimum time for a connection to be throttled if occurring within throttle_threshold_seconds of last attempt.",
            default => 3,
            check_type => 'int',
        }
    );
    Perlbal::Service::add_tunable(
        max_delay => {
            check_role => '*',
            des => "Maximum time for a connection to be throttled after exponential increase from min_delay.",
            default => 300,
            check_type => 'int',
        }
    );
    Perlbal::Service::add_tunable(
        max_concurrent => {
            check_role => '*',
            des => "Maximum number of connections accepted at a time from a single IP, per perlbal instance.",
            default => 2,
            check_type => 'int',
        }
    );
    Perlbal::Service::add_tunable(
        path_regex => {
            check_role => '*',
            des => "Regex which path portion of URI must match for throttling to be in effect.",
        }
    );
    Perlbal::Service::add_tunable(
        method_regex => {
            check_role => '*',
            des => "Regex which HTTP method must match for throttling to be in effect.",
        }
    );
    Perlbal::Service::add_tunable(
        disable_throttling => {
            check_role => '*',
            des => "If true, no address is ever throttled (debug).",
            default => 0,
            check_type => 'bool',
        }
    );
    Perlbal::Service::add_tunable(
        log_only => {
            check_role => '*',
            des => "Perform the full throttling calculation, but don't actually throttle.",
            default => 0,
            check_type => 'bool',
        }
    );
    Perlbal::Service::add_tunable(
        memcached_servers => {
            check_role => '*',
            des => "List of memcached servers to use (memcached will not be used if empty). Cache::Memcached::Async must be installed to use.",
            default => undef,
        }
    );
    Perlbal::Service::add_tunable(
        memcached_async_clients => {
            check_role => '*',
            des => "Number of parallel Cache::Memcached::Async objects to use.",
            check_type => 'int',
            default => 10,
        }
    );
    Perlbal::Service::add_tunable(
        instance_name => {
            check_role => '*',
            des => "Name of throttler instance; instances with the same name will share knowledge of IPs.",
            default => 'default',
        }
    );
    Perlbal::Service::add_tunable(
        ban_threshold => {
            check_role => '*',
            des => "Number of accumulated violations required to temporarily ban the source IP.",
            check_type => 'int',
            default => 0,
        }
    );
    Perlbal::Service::add_tunable(
        ban_expiration => {
            check_role => '*',
            des => "Number of seconds after which banned IP is unbanned.",
            check_type => 'int',
            default => 60,
        }
    );
    Perlbal::Service::add_tunable(
        log_on => {
            check_role => '*',
            des => "Comma-separated list of actions to log on (whitelisted, blacklisted, concurrent, ban, unban, throttle, banned; all).",
            default => 'all',
        }
    );

    Perlbal::register_global_hook('manage_command.throttle', sub {
        my $mc = shift->parse(qr/^
                              throttle\s+
                              (reload) # command
                              $/xi,
                              "usage: throttle reload");
        my ($cmd, $key) = $mc->args;

        my $svcname = $mc->{ctx}{last_created};
        unless ($svcname) {
            return $mc->err("No service name set. This command must be used after CREATE SERVICE <name> or USE <service_name>");
        }

        my $ss = Perlbal->service($svcname);
        return $mc->err("Non-existent service '$svcname'") unless $ss;

        my $cfg = $ss->{extra_config} ||= {};
        my $stash = $cfg->{_throttle_stash} ||= {};

        if ($cfg->{blacklist_file}) {
            eval { $stash->{blacklist} = read_cidr_list($cfg->{blacklist_file}); };
            die "Couldn't load $cfg->{blacklist_file}: $@" if $@ || !$stash->{blacklist};
        }

        if ($cfg->{whitelist_file}) {
            eval { $stash->{whitelist} = read_cidr_list($cfg->{whitelist_file}); };
            die "Couldn't load $cfg->{whitelist_file}: $@" if $@ || !$stash->{whitelist};
        }

        return $mc->ok;
    });
}

# Magical return value constants
use constant HANDLE_REQUEST => 0;
use constant IGNORE_REQUEST => 1;

# indexes into logging flag list
use constant LOG_WHITELISTED => 0;
use constant LOG_BLACKLISTED => 1;
use constant LOG_CONCURRENT  => 2;
use constant LOG_BAN         => 3;
use constant LOG_UNBAN       => 4;
use constant LOG_THROTTLE    => 5;
use constant LOG_BANNED      => 6;

# localized variable to track if a connection has already been throttled
our $DELAYED = 0;

sub register {
    my ($class, $svc) = @_;

    my $cfg = $svc->{extra_config} ||= {};
    my $stash = $cfg->{_throttle_stash} ||= {};

    my %throttled;
    my %banned;

    my $store = PPTStore->new($cfg);

    my $ctx = Perlbal::CommandContext->new;
    $ctx->{last_created} = $svc->{name};
    $ctx->verbose(0);
    Perlbal::run_manage_command('throttle_reload', sub { print STDOUT "$_[0]\n"; }, $ctx);

    my $prefix       = $cfg->{instance_name};
    my $path_regex   = $cfg->{path_regex}   ? qr/$cfg->{path_regex}/   : undef;
    my $method_regex = $cfg->{method_regex} ? qr/$cfg->{method_regex}/ : undef;

    my @log_on = (0) x 7;
    my @log_on_cfg = split /[, ]+/, lc $cfg->{log_on};
    for (@log_on_cfg) {
        @log_on = (1) x 7            if $_ eq 'all';
        $log_on[LOG_WHITELISTED] = 1 if $_ eq 'whitelisted';
        $log_on[LOG_BLACKLISTED] = 1 if $_ eq 'blacklisted';
        $log_on[LOG_CONCURRENT]  = 1 if $_ eq 'concurrent';
        $log_on[LOG_BAN]         = 1 if $_ eq 'ban';
        $log_on[LOG_UNBAN]       = 1 if $_ eq 'unban';
        $log_on[LOG_THROTTLE]    = 1 if $_ eq 'throttle';
        $log_on[LOG_BANNED]      = 1 if $_ eq 'banned';
    }

    my $log_action;
    my $has_syslogger = eval { require Perlbal::Plugin::Syslogger; 1 };
    if ($has_syslogger) {
        VERBOSE and Perlbal::log(info => "Using Perlbal::Plugin::Syslogger");
        $log_action = sub { Perlbal::Plugin::Syslogger::send_syslog_msg($svc, $_[0]) };
    }
    else {
        VERBOSE and Perlbal::log(error => "Perlbal::Plugin::Syslogger unavailable");
        if (VERBOSE) {
            $log_action = sub { Perlbal::log(info => $_[0]) };
        }
        else {
            $log_action = sub { };
        }
    }

    VERBOSE and Perlbal::log(info => "Registering Throttle.");

    my $start_handler = sub {
        my $retval = eval {
            VERBOSE and Perlbal::log(info => "In Throttle ($DELAYED)");

            my $request_time = Time::HiRes::time;

            my Perlbal::ClientProxy $cp = shift;
            unless ($cp) {
                VERBOSE and Perlbal::log(error => "Missing ClientProxy");
                return HANDLE_REQUEST;
            }

            my $headers = $cp->{req_headers};
            unless ($headers) {
                VERBOSE and Perlbal::log(info => "no headers");
                return HANDLE_REQUEST;
            }

            my $ip = $cp->observed_ip_string() || $cp->peer_ip_string;
            unless (defined $ip) {
                # happens if client goes away
                VERBOSE and Perlbal::log(warn => "Client went away");
                $cp->send_response(500, "Internal server error.\n");
                return IGNORE_REQUEST;
            }

            # back from throttling, all later checks were already passed
            return HANDLE_REQUEST if $DELAYED;

            # increment the count of throttled conns
            $throttled{$ip}++;

            # Immediately passthrough whitelistees
            if ($stash->{whitelist} && $stash->{whitelist}->find($ip)) {
                $log_action->("Letting whitelisted ip $ip through") if $log_on[LOG_WHITELISTED];
                return HANDLE_REQUEST;
            }

            # Drop conns from banned/blacklisted IPs
            my $banned = $banned{$ip};
            my $blacklisted = $stash->{blacklist} && $stash->{blacklist}->find($ip);
            if ($banned || $blacklisted) {
                my $msg = sprintf 'Blocking %s IP %s', $banned ? 'banned' : 'blacklisted';
                VERBOSE and Perlbal::log(warn => $msg);
                $log_action->($msg) if $log_on[LOG_BANNED];
                unless ($cfg->{log_only}) {
                    $cp->send_response(403, "Forbidden.\n");
                    return IGNORE_REQUEST;
                }
            }

            if (exists $throttled{$ip} && $throttled{$ip} > $cfg->{max_concurrent}) {
                $log_action->("Too many concurrent connections from $ip") if $log_on[LOG_CONCURRENT];
                unless ($cfg->{log_only}) {
                    $cp->send_response(503, "Too many connections.\n");
                    return IGNORE_REQUEST;
                }
            }

            my $uri    = $headers->request_uri;
            my $method = $headers->request_method;

            # Only throttle matching requests
            if (defined $path_regex && $uri !~ $path_regex) {
                VERBOSE && Perlbal::log(info => '%s', "This isn't a throttled URL: $uri");
                return HANDLE_REQUEST;
            }
            if (defined $method_regex && $method !~ $method_regex) {
                VERBOSE && Perlbal::log(info => '%s', "This isn't a throttled method: $method");
                return HANDLE_REQUEST;
            }

            return HANDLE_REQUEST if $cfg->{disable_throttling};

            # check if we've seen this ip lately.
            my $mc_key = "throttle:$prefix:$ip";
            $store->get($mc_key, timeout => $cfg->{min_delay}, callback => sub {
                my $value = shift;
                my ($last_request_time, $violations);
                if (defined $value) {
                    ($last_request_time, $violations) = unpack 'FS', $value;
                }
                $violations ||= 0;

                $store->set(
                    $mc_key => pack('FS', $request_time, $violations),
                    exptime => $cfg->{throttle_threshold_seconds},
                    timeout => $cfg->{min_delay},
                );

                my $time_since_last_request;
                if (defined $last_request_time) {
                    $time_since_last_request = $request_time - $last_request_time;
                }

                VERBOSE and Perlbal::log(info => "$ip; this request at $request_time; last at %s; interval is %s", $last_request_time||'n/a', $time_since_last_request||'n/a');

                # at this point we're executing in a danga::socket callback
                # after we've already told perlbal to ignore the request.
                # so if we now want it handled it needs to be re-adopted

                my $rehandle = sub {
                    my $delay = shift;
                    $delay = 0 if $cfg->{log_only};
                    Danga::Socket->AddTimer($delay, sub {
                        local $DELAYED = 1;
                        $cp->watch_read(1);
                        $svc->adopt_base_client($cp);
                    });
                    $cp->watch_read(0);
                    return IGNORE_REQUEST;
                };

                # can we let it through immediately?
                return $rehandle->(0) if !defined $time_since_last_request; # haven't seen ip before
                return $rehandle->(0) if $time_since_last_request >= $cfg->{throttle_threshold_seconds}; # waited long enough

                # need to throttle, now figure out by how much. at least
                # min_delay, at most max_delay, exponentially increasing in
                # between
                my $delay = min($cfg->{min_delay} * 2**$violations, $cfg->{max_delay});

                $violations++;

                # banhammer for great justice
                if (
                    $cfg->{ban_threshold} &&
                    $violations >= $cfg->{ban_threshold}
                ) {
                    $log_action->("Banning $ip for $cfg->{ban_expiration}s: $uri") if $log_on[LOG_BAN];
                    $banned{$ip}++ unless $cfg->{log_only};
                    Danga::Socket->AddTimer($cfg->{ban_expiration}, sub {
                        $log_action->("Unbanning $ip") if $log_on[LOG_UNBAN];
                        delete $banned{$ip} unless $cfg->{log_only};
                    });
                    $cp->close;
                    return IGNORE_REQUEST;
                }

                $store->set(
                    $mc_key => pack('FS', $request_time, $violations),
                    exptime => $delay,
                    timeout => $cfg->{min_delay},
                );

                $log_action->("Throttling $ip for $delay: $uri") if $log_on[LOG_THROTTLE];

                # schedule request to be re-handled
                return $rehandle->($delay);
            });

            # make sure we don't take up reading until readoption
            $cp->watch_read(0);
            return IGNORE_REQUEST;
        };
        if ($@) {
            # if something horrible should happen internally, don't take out perlbal
            Perlbal::log(err => "Throttle failed: '%s'", $@);
            return HANDLE_REQUEST;
        }
        else {
            return $retval;
        }
    };

    my $end_handler = sub {
        my Perlbal::ClientProxy $cp = shift;

        my $ip = $cp->observed_ip_string() || $cp->peer_ip_string;
        return unless $ip;

        delete $throttled{$ip} unless --$throttled{$ip} > 0;
    };

    $svc->register_hook(Throttle => start_proxy_request => $start_handler);
    $svc->register_hook(Throttle => end_proxy_request => $end_handler);
}

sub read_cidr_list {
    my $file = shift;

    require Net::CIDR::Lite;

    my $empty = 1;
    my $list = Net::CIDR::Lite->new;

    open my $fh, '<', $file or die "Unable to open file $file: $!";
    while (my $line = <$fh>) {
        $line =~ s/#.*//; # comments
        if ($line =~ /([0-9\/\.]+)/) {
            my $cidr = $1;
            if (index($cidr, "/") < 0) {
                $list->add_ip($cidr);
            }
            else {
                $list->add($cidr);
            }
            $empty = 0;
        }
    }

    die "$file is empty\n" if $empty;

    return $list;
}

package PPTStore;

sub new {
    my $class = shift;
    my $cfg = shift;

    my $want_memcached = $cfg->{memcached_servers};
    my $has_memcached = eval { require Cache::Memcached::Async; 1 };

    if ($want_memcached && !$has_memcached) {
        die "memcached support requested but Cache::Memcached::Async failed to load: $@\n";
    }
    return $want_memcached
        ? PPTStore::Memcached->new($cfg)
        : PPTStore::Memory->new($cfg);
}

package PPTStore::Memcached;

sub new {
    my $class = shift;
    my $cfg = shift;

    my @servers = split /[,\s]+/, $cfg->{memcached_servers};
    my @cxns = map {
        Cache::Memcached::Async->new({ servers => \@servers })
    } 1 .. $cfg->{memcached_async_clients};

    return bless \@cxns, $class;
}

sub get {
    my $self = shift;
    return $self->[rand @$self]->get(@_);
}

sub set {
    my $self = shift;
    return $self->[rand @$self]->set(@_);
}

package PPTStore::Memory;

sub new {
    my $class = shift;
    my $cfg = shift;
    return bless {}, $class;
}

sub get {
    my $self = shift;
    my $key = shift;
    my %params = @_;
    my $entry = $self->{$key};
    my $value = $entry ? (time < $entry->[0] ? $entry->[1] : undef) : undef;
    $params{callback}->($value);
    return;
}

sub set {
    my $self = shift;
    my $key = shift;
    my $value = shift;
    my %params = @_;
    $self->{$key} = [$params{exptime}, $value];
    return;
}

1;

__END__

=head1 NAME

Perlbal::Plugin::Throttle - Perlbal plugin that throttles connections from
hosts that connect too frequently.

=head1 OVERVIEW

This plugin intercepts HTTP requests to a Perlbal service and slows or drops
connections from IP addresses which are determined to be connecting too fast.

=head1 BEHAVIOR

An IP address address may be in one of four states depending on its recent
activity; that state determines how new requests from the IP are handled:

=over 4

=item * B<allowed>

An IP begins in the B<allowed> state. When a request is received from an IP in
this state, the request is handled immediately and the IP enters the
B<probation> state.

=item * B<probation>

If no requests are received from an IP in the B<probation> state for
I<throttle_threshold_seconds>, it returns to the B<allowed> state.

When a new request is received from an IP in the B<probation> state, the IP
enters the B<throttled> state and is assigned a I<delay> property initially
equal to I<min_delay>. Connection to a backend is postponed for I<delay>
seconds while perlbal continues to work. If the connection is still open after
the delay, the request is then handled normally. A dropped connection does not
change the IP's I<delay> value.

=item * B<throttled>

If no requests are received from an IP in the B<throttled> state for
I<delay> seconds, it returns to the B<probation> state.

When a new request is received from an IP in the B<throttled> state, its
I<violations> property is incremented, and its I<delay> property is
doubled (up to a maximum of I<max_delay>). The request is postponed for the new
value of I<delay>.

Only after the most recently created connection from a given IP exits the
B<throttled> state do I<violations> and I<delay> reset to 0.

Furthermore, if the I<violations> exceeds I<ban_threshold>, the connection
is closed and the IP moves to the B<banned> state.

IPs in the B<throttled> state may have no more than I<max_concurrent>
connections being delayed at once. Any additional requests received in that
circumstance are sent a "503 Too many connections" response. Long-running
requests which have already been connected to a backend do not count towards
this limit.

=item * B<banned>

New connections from IPs in the banned state are immediately closed with a 403
error response.

An IP leaves the B<banned> state after I<ban_expiration> seconds have
elapsed.

=back

=head1 FEATURES

=over 4

=item * IP whitelist

IPs/CIDRs listed in the file specified by I<whitelist_file> are never
throttled.

=item * IP blacklist

Connections from IPs/CIDRs listed in the file specified by I<blacklist_file>
immediately sent a "403 Forbidden" response.

=item * Path specificity

Throttling may be restricted to URI paths matching the I<path_regex> regex.

=item * External shared state

The plugin stores state which IPs have been seen in a memcached(1) instance.
This allows many throttlers to share their state and also minimizes memory use
within the perlbal. If state exceeds the capacity of the memcacheds, the
least-recently seen IPs will be forgotten, effectively resetting them to the
B<allowed> state.

Orthogonally, multiple throttlers which need to share memcacheds but not state
may specify distinct B<instance_name> values.

=item * Logging

If Perlbal::Plugin::Syslogger is installed and registered with the service,
Throttle can use it to send syslog messages regarding events. Granular
control for which events are logged is available via the B<log_on> parameter.

=back

=head1 OPTIONAL DEPENDENCIES

=over 4

=item * Cache::Memcached::Async

Required for memcached support. This is an easy way to share
state between different perlbal instances.

=item * Net::CIDR::Lite

Required for blacklist/whitelist support.

=item * Perlbal::Plugin::Syslogger

Required for asynchronous logging support.

=back

=head1 CAVEATS

=over 4

=item * List loading is blocking

The B<throttle reload> management command loads the whitelist and blacklist
files synchronously, which will cause the perlbal to hang until it completes.

=item * Redirects

If a handled request returns a 30x response code and the redirect URI is also
throttled, then the client's attempt to follow the redirect will necessarily be
delayed by B<min_delay>. Fixing this would require that the plugin inspect the
HTTP response headers, which would incur a lot of overhead. To workaround, try
to have your backend not return 30x's if both the original and redirect URI are
proxied by the same throttler instance (yes, this is difficult for the case
where a backend 302s to add a trailing / to a directory).

=back

=head1 SEE ALSO

=over 4

=item * List of tunables in Throttle.pm.

=back

=head1 TODO

=over 4

=item * Fix white/blacklist loading

Load CIDR lists asynchronously (perhaps in the manner of
Perlbal::Pool::_load_nodefile_async).

=back

=head1 AUTHOR

Adam Thomason, E<lt>athomason@cpan.orgE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2007-2011 by Say Media Inc, E<lt>cpan@sixapart.comE<gt>

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself, either Perl version 5.8.6 or, at your option,
any later version of Perl 5 you may have available.

=cut
