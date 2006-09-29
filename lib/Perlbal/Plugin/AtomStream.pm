package Perlbal::Plugin::AtomStream;

use URI;

use Perlbal;
use strict;
use warnings;

our @subs;    # subscribers
our @recent;  # recent items in format [$epoch, $atom_ref, $path_segments_arrayref]

our $last_timestamp = 0;

use constant MAX_LAG => 262144;

sub InjectFeed {
    my $class = shift;
    my ($atomref, $path) = @_;

    # maintain queue of last 60 seconds worth of posts
    my $now = time();
    my @put_segments = URI->new($path)->path_segments;
    push @recent, [ $now, $atomref, \@put_segments ];
    shift @recent while @recent && $recent[0][0] <= $now - 60;

    emit_timestamp($now) if $now > $last_timestamp;

    my $need_clean = 0;
    foreach my $s (@subs) {
        if ($s->{closed}) {
            $need_clean = 1;
            next;
        }

        next unless filter(\@put_segments, $s->{scratch}{get_segments});
        
        my $lag = $s->{write_buf_size};

        if ($lag > MAX_LAG) {
            $s->{scratch}{skipped_atom}++;
        } else {
            if (my $skip_count = $s->{scratch}{skipped_atom}) {
                $s->{scratch}{skipped_atom} = 0;
                $s->write(\ "<sorryTooSlow youMissed=\"$skip_count\" />\n");
            }
            $s->watch_write(0) if $s->write($atomref);
        }
    }

    if ($need_clean) {
        @subs = grep { ! $_->{closed} } @subs;
    }
}

sub emit_timestamp {
    my $time = shift;
    $last_timestamp = $time;
    foreach my $s (@subs) {
        next if $s->{closed};
        $s->{alive_time} = $time;
        $s->write(\ "<time>$time</time>\n");
    }
}

sub filter {
    my ($put, $get) = @_;
    return 0 if scalar @$put < scalar @$get;
    for( my $i = 0 ; $i < scalar @$get ; $i++) {
        return 0 if $put->[$i] ne $get->[$i];
    }
    return 1;
}

# called when we're being added to a service
sub register {
    my ($class, $svc) = @_;

    Perlbal::Socket::register_callback(1, sub {
        my $now = time();
        emit_timestamp($now) if $now > $last_timestamp;
        return 1;
    });

    $svc->register_hook('AtomStream', 'start_http_request', sub {
        my Perlbal::ClientProxy $self = shift;
        my Perlbal::HTTPHeaders $hds = $self->{req_headers};
        return 0 unless $hds;
        my $uri = URI->new($hds->request_uri);
        my @get_segments = $uri->path_segments;
        $self->{scratch}{get_segments} = \@get_segments;
        return 0 unless pop @get_segments eq 'atom-stream.xml';
        my %params = $uri->query_form;
        my $since = $params{since} =~ /\d+/ ? $params{since} : 0;

        my $res = $self->{res_headers} = Perlbal::HTTPHeaders->new_response(200);
        $res->header("Content-Type", "text/xml");
        $res->header('Connection', 'close');

        push @subs, $self;

        $self->write($res->to_string_ref);

        my $last_rv = $self->write(\ "<?xml version='1.0' encoding='utf-8' ?>\n<atomStream><!-- since=$since -->\n");

        # if they'd like a playback, give them all items >= time requested
        if ($since) {
            foreach my $item (@recent) {
                next if $item->[0] < $since;
                next unless filter($item->[2], \@get_segments);
                $last_rv = $self->write($item->[1]);
            }
        }

        $self->watch_write(0) if $last_rv;
        return 1;
    });

    return 1;
}

# called when we're no longer active on a service
sub unregister {
    my ($class, $svc) = @_;

    return 1;
}

# called when we are loaded
sub load {
    return 1;
}

# called for a global unload
sub unload {
    return 1;
}

1;
